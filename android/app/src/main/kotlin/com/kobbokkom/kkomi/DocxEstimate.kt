package com.kobbokkom.kkomi

import android.content.Context
import android.net.Uri
import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.Locale
import java.util.zip.ZipFile

private fun InputStream.copyBoundedTo(output: OutputStream? = null, limit: Long): Long {
    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
    var total = 0L
    while (true) {
        val count = read(buffer)
        if (count == -1) return total
        total += count
        if (total > limit) throw IOException("Office file is too large")
        output?.write(buffer, 0, count)
    }
}

private fun InputStream.startsWith(prefix: ByteArray): Boolean =
    prefix.all { read() == (it.toInt() and 0xff) }

private const val OFFICE_NAMESPACE = "http://schemas.openxmlformats.org"
private const val STRICT_OFFICE_NAMESPACE = "http://purl.oclc.org/ooxml"
private const val CONTENT_TYPES_NAMESPACE = "$OFFICE_NAMESPACE/package/2006/content-types"
private const val RELATIONSHIPS_NAMESPACE = "$OFFICE_NAMESPACE/package/2006/relationships"
private const val MAX_MANIFEST_BYTES = 2 * 1024 * 1024L
private const val DOCX_MAIN_PART = "word/document.xml"
private const val MAX_DOCX_ESTIMATE_BYTES = 8 * 1024 * 1024L
private const val MAX_DOCX_ESTIMATE_EXPANDED = 32 * 1024 * 1024L

internal fun docxEstimateBytes(context: Context, uri: Uri): ByteArray {
    require(uri.scheme == "content")
    val source = File.createTempFile("docx-estimate-", ".tmp", context.cacheDir)
    try {
        val input = context.contentResolver.openInputStream(uri) ?: throw IOException("Unable to read DOCX")
        input.use { stream ->
            source.outputStream().use { stream.copyBoundedTo(it, MAX_DOCX_ESTIMATE_BYTES) }
        }
        validateDocx(source)
        return source.readBytes()
    } finally {
        source.delete()
    }
}

private fun validateDocx(file: File) {
    require(file.inputStream().use { it.startsWith(byteArrayOf(0x50, 0x4b, 0x03, 0x04)) })
    ZipFile(file).use { zip ->
        require(zip.size() <= 10_000)
        val entries = mutableSetOf<String>()
        val stream = zip.entries()
        val expandedLimit = MAX_DOCX_ESTIMATE_EXPANDED
        var expanded = 0L
        while (stream.hasMoreElements()) {
            val entry = stream.nextElement()
            val name = entry.name
            require(entry.size in 0..expandedLimit - expanded)
            require(
                entries.add(name.lowercase(Locale.ROOT)) && !name.startsWith('/') && '\\' !in name &&
                    name.split('/').none { it == "." || it == ".." }
            )
            // HWPX uses an OCF-style mimetype entry and a Contents/ directory.
            require(!name.equals("mimetype", ignoreCase = true) && !name.startsWith("Contents/", ignoreCase = true))
            if (!entry.isDirectory) {
                val actual = zip.getInputStream(entry).use { it.copyBoundedTo(limit = expandedLimit - expanded) }
                require(actual == entry.size)
            }
            expanded += entry.size
        }
        var matchedMainPart = false
        zip.inspectXml("[Content_Types].xml", "Types", setOf(CONTENT_TYPES_NAMESPACE), true) { parser ->
            if (parser.depth == 2 && parser.name == "Override" && parser.namespace == CONTENT_TYPES_NAMESPACE &&
                parser.getAttributeValue(null, "PartName") == "/$DOCX_MAIN_PART"
            ) {
                val contentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
                require(!matchedMainPart && parser.getAttributeValue(null, "ContentType") == contentType)
                matchedMainPart = true
            }
        }
        require(matchedMainPart)
        var matchedRelationship = false
        zip.inspectXml("_rels/.rels", "Relationships", setOf(RELATIONSHIPS_NAMESPACE), true) { parser ->
            if (parser.depth == 2 && parser.name == "Relationship" && parser.namespace == RELATIONSHIPS_NAMESPACE) {
                val relationship = parser.getAttributeValue(null, "Type")
                if (relationship == "$OFFICE_NAMESPACE/officeDocument/2006/relationships/officeDocument" ||
                    relationship == "$STRICT_OFFICE_NAMESPACE/officeDocument/relationships/officeDocument"
                ) {
                    val target = parser.getAttributeValue(null, "Target").orEmpty().removePrefix("/")
                    val mode = parser.getAttributeValue(null, "TargetMode")
                    require(!matchedRelationship && target == DOCX_MAIN_PART && (mode == null || mode == "Internal"))
                    matchedRelationship = true
                }
            }
        }
        require(matchedRelationship)
        zip.inspectXml(DOCX_MAIN_PART, "document", setOf(
            "$OFFICE_NAMESPACE/wordprocessingml/2006/main",
            "$STRICT_OFFICE_NAMESPACE/wordprocessingml/main",
        ), false) {}
    }
}

private fun ZipFile.inspectXml(
    part: String,
    root: String,
    namespaces: Set<String>,
    complete: Boolean,
    inspect: (XmlPullParser) -> Unit,
) {
    val entry = getEntry(part) ?: throw IOException("Missing Office package part")
    require(!entry.isDirectory && (!complete || entry.size in 1..MAX_MANIFEST_BYTES))
    getInputStream(entry).buffered().use { input ->
        val parser = Xml.newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
        parser.setInput(LimitedXmlInput(input), null)
        var sawRoot = false
        while (parser.nextToken() != XmlPullParser.END_DOCUMENT) {
            require(parser.eventType != XmlPullParser.DOCDECL)
            if (parser.eventType != XmlPullParser.START_TAG) continue
            if (parser.depth == 1) {
                require(!sawRoot && parser.name == root && parser.namespace in namespaces)
                sawRoot = true
                if (!complete) return
            }
            inspect(parser)
        }
        require(sawRoot)
    }
}

private class LimitedXmlInput(input: InputStream) : java.io.FilterInputStream(input) {
    private var remaining = MAX_MANIFEST_BYTES + 1

    override fun read(): Int {
        require(remaining > 0)
        return super.read().also { if (it >= 0) remaining-- }
    }

    override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        require(remaining > 0)
        return super.read(bytes, offset, minOf(length.toLong(), remaining).toInt()).also {
            if (it > 0) remaining -= it
        }
    }
}
