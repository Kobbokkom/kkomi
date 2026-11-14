package com.kobbokkom.kkomi

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.net.Uri
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import java.io.BufferedInputStream
import java.io.BufferedReader
import java.io.File
import java.io.FilterOutputStream
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStream
import java.io.PushbackReader
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

private const val A4_WIDTH = 595
private const val A4_HEIGHT = 842
private const val TXT_PAGE_MARGIN = 40
private const val CSV_PAGE_MARGIN = 57
private const val TXT_LINES_PER_PAGE = 50
private const val CSV_COLUMNS_PER_BAND = 10
private const val CSV_HORIZONTAL_PADDING = 4
private const val CSV_VERTICAL_PADDING = 3
private const val MAX_PDF_PAGES = 1000
private const val MAX_FIELD_LENGTH = 65536
private const val MAX_CSV_FIELDS = 256

internal fun convertTextPdf(context: Context, uri: Uri, extension: String, name: String): File {
    val delimiter = when (extension) {
        "txt" -> null
        "csv" -> ','
        "tsv" -> '\t'
        else -> throw IllegalArgumentException("Unsupported text format")
    }
    // Validate and replay the same bytes when the provider serves a live or remote stream.
    val source = File.createTempFile("kkomi-text-input-", ".tmp", context.cacheDir)
    try {
        val input = context.contentResolver.openInputStream(uri) ?: throw IOException("Cannot open text document")
        input.use { stream ->
            BoundedOutput(source.outputStream().buffered()).use { stream.copyTo(it) }
        }
        val encoding = detectEncoding(source)
        val directory = File(context.cacheDir, "converted")
        if (!directory.mkdirs() && !directory.isDirectory) throw IOException("Cannot create PDF cache")
        val output = File.createTempFile("kkomi-text-", ".pdf", directory)
        try {
            val width = if (delimiter != null) A4_HEIGHT else A4_WIDTH
            val height = if (delimiter != null) A4_WIDTH else A4_HEIGHT
            val margin = if (delimiter != null) CSV_PAGE_MARGIN else TXT_PAGE_MARGIN
            TextPdf(width, height, margin).use { pdf ->
                val openSource = { openText(source, encoding) }
                if (delimiter != null) pdf.writeTable(openSource, name, delimiter) else openSource().use(pdf::writeText)
                BoundedOutput(output.outputStream().buffered()).use(pdf.document::writeTo)
            }
            return output
        } catch (error: Throwable) {
            output.delete()
            throw error
        }
    } finally {
        source.delete()
    }
}

private data class TextEncoding(val charset: Charset, val bomBytes: Int = 0)

private fun detectEncoding(file: File): TextEncoding {
    file.inputStream().buffered().use { source ->
        val first = source.read()
        val second = source.read()
        if (first == 0xff && second == 0xfe) return TextEncoding(Charsets.UTF_16LE, 2)
        if (first == 0xfe && second == 0xff) return TextEncoding(Charsets.UTF_16BE, 2)
        if (first == 0xef && second == 0xbb && source.read() == 0xbf) return TextEncoding(Charsets.UTF_8, 3)
    }
    val utf8 = TextEncoding(Charsets.UTF_8)
    try {
        openText(file, utf8).use { source ->
            val buffer = CharArray(8192)
            while (source.read(buffer) != -1) {
                // Validate unmarked UTF-8 before selecting the Korean legacy encoding.
            }
        }
    } catch (_: CharacterCodingException) {
        return TextEncoding(Charset.forName("windows-949"))
    }
    return utf8
}

private fun openText(file: File, encoding: TextEncoding): BufferedReader {
    val decoder = encoding.charset.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
    val source = BufferedInputStream(file.inputStream())
    repeat(encoding.bomBytes) { source.read() }
    return InputStreamReader(source, decoder).buffered()
}

private class BoundedOutput(target: OutputStream) : FilterOutputStream(target) {
    private var remaining = MAX_DOCUMENT_BYTES

    override fun write(byte: Int) {
        if (remaining == 0L) throw IOException("Text conversion file is too large")
        remaining--
        out.write(byte)
    }

    override fun write(buffer: ByteArray, offset: Int, count: Int) {
        if (count > remaining) throw IOException("Text conversion file is too large")
        remaining -= count
        out.write(buffer, offset, count)
    }
}

private fun textPaint(size: Float, bold: Boolean = false) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.BLACK
    textSize = size
    typeface = Typeface.create("sans-serif", if (bold) Typeface.BOLD else Typeface.NORMAL)
}

private class TextPdf(private val width: Int, private val height: Int, private val margin: Int) : AutoCloseable {
    val document = PdfDocument()
    private val contentWidth = width - 2 * margin
    private val bottom = height - margin
    private var page: PdfDocument.Page? = null
    private var pageNumber = 0
    private var top = margin
    private val text = textPaint(11f)
    private val cell = textPaint(10f)
    private val header = textPaint(10f, bold = true)
    private val caption = textPaint(18f, bold = true)
    private val grid = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.LTGRAY
        strokeWidth = 0.5f
        style = Paint.Style.STROKE
    }
    private val headerFill = Paint().apply { color = Color.rgb(244, 246, 248) }
    private val canvas: Canvas get() = requireNotNull(page).canvas

    private fun startPage() {
        finishPage()
        if (pageNumber >= MAX_PDF_PAGES) throw IOException("Text PDF has too many pages")
        page = document.startPage(PdfDocument.PageInfo.Builder(width, height, ++pageNumber).create())
        top = margin
    }

    private fun finishPage() {
        page?.let(document::finishPage)
        page = null
    }

    private fun layout(value: CharSequence, paint: TextPaint, lineWidth: Int): StaticLayout =
        StaticLayout.Builder.obtain(value, 0, value.length, paint, lineWidth)
            .setIncludePad(false)
            .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
            .build()

    private fun draw(layout: StaticLayout, x: Int, y: Int, start: Int = 0, end: Int = layout.lineCount) {
        canvas.save()
        try {
            val startY = layout.getLineTop(start)
            canvas.translate(x.toFloat(), (y - startY).toFloat())
            canvas.clipRect(0, startY, layout.width, layout.getLineTop(end))
            layout.draw(canvas)
        } finally {
            canvas.restore()
        }
    }

    fun writeText(source: BufferedReader) {
        startPage()
        var logicalLines = 0
        while (true) {
            val line = source.readBoundedLine() ?: break
            if (logicalLines == TXT_LINES_PER_PAGE) {
                startPage()
                logicalLines = 0
            }
            logicalLines++
            val block = layout(line, text, contentWidth)
            var firstLine = 0
            while (firstLine < block.lineCount) {
                val lastLine = linesThatFit(block, firstLine, bottom - top)
                if (lastLine == firstLine) {
                    startPage()
                    continue
                }
                draw(block, margin, top, firstLine, lastLine)
                top += block.getLineTop(lastLine) - block.getLineTop(firstLine) + 2
                firstLine = lastLine
            }
        }
        finishPage()
    }

    fun writeTable(openSource: () -> BufferedReader, name: String, delimiter: Char) {
        val columnCount = openSource().use { source ->
            val rows = DelimitedRows(source, delimiter)
            var maxColumns = 0
            while (true) maxColumns = maxOf(maxColumns, rows.next()?.size ?: break)
            maxColumns
        }
        val title = layout(name.take(256), caption, contentWidth)
        if (columnCount == 0) {
            startPage()
            draw(title, margin, top)
            finishPage()
            return
        }
        // Replay wide tables one column band at a time so each band flows across pages.
        for (from in 0 until columnCount step CSV_COLUMNS_PER_BAND) {
            openSource().use { source ->
                val rows = DelimitedRows(source, delimiter)
                val count = minOf(columnCount - from, CSV_COLUMNS_PER_BAND)
                fun cells(row: List<String>) = List(count) { row.getOrElse(from + it) { "" } }
                val names = cells(rows.next().orEmpty())
                fun beginBandPage() {
                    startPage()
                    draw(title, margin, top)
                    top += title.height + 16
                    drawCells(names, header, heading = true, reserve = 120)
                }

                beginBandPage()
                while (true) drawCells(cells(rows.next() ?: break), cell, nextPage = ::beginBandPage)
            }
        }
        finishPage()
    }

    private fun drawCells(
        values: List<String>,
        paint: TextPaint,
        heading: Boolean = false,
        reserve: Int = 0,
        nextPage: (() -> Unit)? = null,
    ) {
        val cellWidth = contentWidth / values.size
        val textWidth = cellWidth - 2 * CSV_HORIZONTAL_PADDING
        val blocks = values.map { layout(it, paint, textWidth) }
        val firstLines = IntArray(blocks.size)
        do {
            val space = bottom - top - 2 * CSV_VERTICAL_PADDING - reserve
            val lastLines = IntArray(blocks.size) { linesThatFit(blocks[it], firstLines[it], space) }
            if (firstLines.indices.any { firstLines[it] < blocks[it].lineCount && lastLines[it] == firstLines[it] }) {
                if (nextPage == null) throw IOException("CSV header is too tall")
                nextPage()
                continue
            }
            val rowHeight = firstLines.indices.maxOf {
                blocks[it].getLineTop(lastLines[it]) - blocks[it].getLineTop(firstLines[it])
            } + 2 * CSV_VERTICAL_PADDING
            for (index in blocks.indices) {
                val left = margin + index * cellWidth
                val right = left + cellWidth
                if (heading) canvas.drawRect(left.toFloat(), top.toFloat(), right.toFloat(), (top + rowHeight).toFloat(), headerFill)
                canvas.drawRect(left.toFloat(), top.toFloat(), right.toFloat(), (top + rowHeight).toFloat(), grid)
                if (lastLines[index] > firstLines[index]) {
                    draw(blocks[index], left + CSV_HORIZONTAL_PADDING, top + CSV_VERTICAL_PADDING,
                         firstLines[index], lastLines[index])
                }
                firstLines[index] = lastLines[index]
            }
            top += rowHeight
        } while (firstLines.indices.any { firstLines[it] < blocks[it].lineCount })
    }

    private fun linesThatFit(block: StaticLayout, start: Int, space: Int): Int {
        var end = start
        while (end < block.lineCount && block.getLineTop(end + 1) - block.getLineTop(start) <= space) end++
        return end
    }

    override fun close() {
        finishPage()
        document.close()
    }
}

private fun BufferedReader.readBoundedLine(): String? {
    val line = StringBuilder()
    while (true) {
        when (val code = read()) {
            -1 -> return line.toString().takeIf { it.isNotEmpty() }
            '\n'.code -> return line.toString()
            '\r'.code -> {
                mark(1)
                if (read() != '\n'.code) reset()
                return line.toString()
            }
            else -> line.appendFieldChar(code.toChar())
        }
    }
}

private fun StringBuilder.appendFieldChar(value: Char) {
    if (length == MAX_FIELD_LENGTH) throw IOException("Text field is too long")
    append(value)
}

private class DelimitedRows(reader: BufferedReader, private val delimiter: Char) {
    private val source = PushbackReader(reader)

    fun next(): List<String>? {
        val values = mutableListOf<String>()
        val field = StringBuilder()
        var quoted = false
        var seen = false
        while (true) {
            val code = source.read()
            when {
                code == -1 -> {
                    if (quoted) throw IOException("Unclosed table field quote")
                    if (!seen) return null
                    break
                }
                code == '"'.code && quoted -> {
                    val following = source.read()
                    if (following == '"'.code) {
                        field.appendFieldChar('"')
                    } else {
                        quoted = false
                        if (following != -1) source.unread(following)
                    }
                }
                quoted -> field.appendFieldChar(code.toChar())
                code == '"'.code && field.isEmpty() -> quoted = true
                code == delimiter.code -> {
                    if (values.size == MAX_CSV_FIELDS - 1) throw IOException("Table has too many columns")
                    values.add(field.toString())
                    field.setLength(0)
                }
                code == '\n'.code -> break
                code == '\r'.code -> {
                    val following = source.read()
                    if (following != -1 && following != '\n'.code) source.unread(following)
                    break
                }
                else -> field.appendFieldChar(code.toChar())
            }
            seen = true
        }
        values.add(field.toString())
        return values
    }
}
