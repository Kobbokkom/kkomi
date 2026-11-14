package com.kobbokkom.kkomi

import android.content.Context
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.util.Xml
import androidx.core.content.FileProvider
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URI
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.DigestInputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipFile

private data class OfficeType(
    val part: String,
    val family: String,
    val root: String,
    val type: String,
)

private val openXmlTypes = mapOf(
    "docx" to OfficeType("word/document.xml", "wordprocessingml", "document", "wordprocessingml.document"),
    "xlsx" to OfficeType("xl/workbook.xml", "spreadsheetml", "workbook", "spreadsheetml.sheet"),
    "pptx" to OfficeType("ppt/presentation.xml", "presentationml", "presentation", "presentationml.presentation"),
)
private val legacyTypes = setOf("doc", "xls", "ppt")
private const val MAX_CACHED_OFFICE_PDFS = 10
private const val MAX_OFFICE_CACHE_BYTES = 128L * 1024 * 1024
private val cachedPdfName = Regex("[0-9a-f]{64}-[0-9a-f]{64}\\.pdf")
private val pdfMagic = "%PDF-".toByteArray(Charsets.US_ASCII)
private val pdfTrailer = Regex("startxref\\s+(\\d+)\\s+%%EOF\\s*$")
private val pdfCrossReference = Regex("^(xref\\s|\\d+\\s+\\d+\\s+obj\\b)")
private val conversionDeadlines = ScheduledThreadPoolExecutor(1) { task ->
    Thread(task, "office-conversion-timeout").apply { isDaemon = true }
}.apply { removeOnCancelPolicy = true }

internal fun officeConverterAvailable(context: Context, endpoint: String): Boolean =
    runCatching { converterUrl(context, endpoint, "docx") }.isSuccess

// Run on the same IO executor as convertOffice and forgetOfficePdf.
internal fun cachedOfficePdf(context: Context, documentUri: Uri, extension: String, endpoint: String): Uri? {
    if (documentUri.scheme != "content" || (extension !in openXmlTypes && extension !in legacyTypes)) return null
    val url = converterUrl(context, endpoint, extension)
    val prefix = cachePrefix(documentUri)
    val directory = officeCacheDirectory(context)
    if (directory.listFiles().orEmpty().none { it.name.startsWith(prefix) }) return null

    val digest = MessageDigest.getInstance("SHA-256")
    openOfficeInput(context, documentUri).use { input ->
        DigestInputStream(input, digest).copyBoundedTo()
    }
    return openCachedOfficePdf(context, cacheFile(context, prefix, url, digest.digest()))
}

internal fun forgetOfficePdf(context: Context, documentUri: Uri) {
    val prefix = cachePrefix(documentUri)
    for (file in officeCacheDirectory(context).listFiles().orEmpty()) {
        if (file.name.startsWith(prefix)) file.delete()
    }
}

// Run on an IO executor. Only the validated, private copy is sent to the converter.
internal fun convertOffice(
    context: Context,
    documentUri: Uri,
    extension: String,
    endpoint: String,
    token: String? = null,
): Uri {
    val type = openXmlTypes[extension]
    require(type != null || extension in legacyTypes)
    val url = converterUrl(context, endpoint, extension)
    require(documentUri.scheme == "content")
    val cached = token.isNullOrBlank()
    val source = File.createTempFile("office-input-", ".tmp", context.cacheDir)
    try {
        val digest = MessageDigest.getInstance("SHA-256")
        openOfficeInput(context, documentUri).use { stream ->
            source.outputStream().use { DigestInputStream(stream, digest).copyBoundedTo(it) }
        }
        if (type == null) {
            validateLegacyOffice(source, extension)
        } else {
            validateOpenXml(source, type)
        }

        val cache = cacheFile(context, cachePrefix(documentUri), url, digest.digest())
        if (cached) runCatching { openCachedOfficePdf(context, cache) }.getOrNull()?.let { return it }
        val output = newOfficePdf(context)
        try {
            requestPdf(url, source, output, token)
            val uri = officePdfUri(context, output)
            // An unavailable cache must not prevent opening a successful conversion.
            if (cached) runCatching { persistOfficePdf(output, cache) }
            return uri
        } catch (error: Exception) {
            output.delete()
            throw error
        }
    } finally {
        source.delete()
    }
}

private fun openOfficeInput(context: Context, uri: Uri): InputStream =
    context.contentResolver.openInputStream(uri) ?: throw IOException("Unable to read Office document")

private fun officeCacheDirectory(context: Context) = File(context.cacheDir, "office_pdfs")

private fun cachePrefix(uri: Uri): String =
    MessageDigest.getInstance("SHA-256").digest(uri.toString().toByteArray()).hex() + "-"

private fun cacheFile(context: Context, prefix: String, url: URL, contentDigest: ByteArray): File {
    val key = MessageDigest.getInstance("SHA-256")
    key.update(contentDigest)
    key.update(url.toExternalForm().toByteArray())
    return File(officeCacheDirectory(context), "$prefix${key.digest().hex()}.pdf")
}

private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }

private fun newOfficePdf(context: Context): File {
    val directory = File(context.cacheDir, "converted")
    if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Unable to create conversion cache")
    return File.createTempFile("kkomi-office-", ".pdf", directory)
}

private fun officePdfUri(context: Context, file: File): Uri =
    FileProvider.getUriForFile(context, "${context.packageName}.documents", file)

private fun openCachedOfficePdf(context: Context, cache: File): Uri? {
    if (!cache.isFile) return null
    if (!hasPdfStructure(cache)) {
        cache.delete()
        return null
    }
    val output = newOfficePdf(context)
    try {
        cache.inputStream().use { input -> output.outputStream().use { input.copyBoundedTo(it) } }
        val uri = officePdfUri(context, output)
        cache.setLastModified(System.currentTimeMillis())
        return uri
    } catch (error: Exception) {
        output.delete()
        throw error
    }
}

private fun persistOfficePdf(output: File, cache: File) {
    val directory = requireNotNull(cache.parentFile)
    if (!directory.isDirectory && !directory.mkdirs()) return
    val pending = File.createTempFile("pending-", ".tmp", directory)
    try {
        output.inputStream().use { input -> pending.outputStream().use { input.copyBoundedTo(it) } }
        if (!pending.renameTo(cache)) return
    } finally {
        pending.delete()
    }
    var count = 0
    var bytes = 0L
    val recent = directory.listFiles().orEmpty().filter { it.isFile && cachedPdfName.matches(it.name) }
        .sortedByDescending(File::lastModified)
    for (file in recent) {
        val length = file.length()
        if (count >= MAX_CACHED_OFFICE_PDFS || length > MAX_OFFICE_CACHE_BYTES - bytes) {
            file.delete()
        } else {
            count++
            bytes += length
        }
    }
}

private fun converterUrl(context: Context, endpoint: String, extension: String): URL {
    val base = URI(endpoint.trim())
    val debug = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
    require(base.scheme == "https" || (debug && base.scheme == "http" && base.host == "127.0.0.1"))
    require(base.host != null && base.userInfo == null && base.rawQuery == null && base.rawFragment == null)
    require(base.port == -1 || base.port in 1..65535)
    val path = base.rawPath.trimEnd('/')
    require(path == base.path.trimEnd('/') && path.split('/').all { it != "." && it != ".." })
    val host = base.host.lowercase(Locale.ROOT)
    val port = base.port.takeUnless { it == if (base.scheme == "https") 443 else 80 } ?: -1
    return URI(base.scheme, null, host, port, "$path/convert/$extension", null, null).toURL()
}

private fun requestPdf(url: URL, source: File, output: File, token: String?) {
    val connection = (if (url.protocol == "http") url.openConnection(Proxy.NO_PROXY)
        else url.openConnection()) as HttpURLConnection
    val expired = AtomicBoolean()
    val timeout = conversionDeadlines.schedule({
        expired.set(true)
        connection.disconnect()
    }, 120, TimeUnit.SECONDS)
    try {
        connection.instanceFollowRedirects = false
        connection.requestMethod = "POST"
        connection.connectTimeout = 10_000
        connection.readTimeout = 90_000
        connection.useCaches = false
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/octet-stream")
        connection.setRequestProperty("Accept", "application/pdf")
        connection.setRequestProperty("Accept-Encoding", "identity")
        if (!token.isNullOrBlank()) {
            require(Regex("[A-Za-z0-9._~+/-]+=*").matches(token))
            connection.setRequestProperty("Authorization", "Bearer $token")
        }
        connection.setFixedLengthStreamingMode(source.length())
        connection.outputStream.use { request -> source.inputStream().use { it.copyTo(request) } }
        if (connection.responseCode != HttpURLConnection.HTTP_OK ||
            !connection.contentType.orEmpty().substringBefore(';').trim().equals("application/pdf", ignoreCase = true) ||
            connection.contentLengthLong > MAX_DOCUMENT_BYTES
        ) throw IOException("Office converter did not return a PDF")
        val length = connection.contentLengthLong
        val copied = connection.inputStream.use { input ->
            output.outputStream().use { input.copyBoundedTo(it) }
        }
        if ((length >= 0 && copied != length) || !hasPdfStructure(output)) {
            throw IOException("Office converter returned an invalid PDF")
        }
        if (expired.get()) throw IOException("Office conversion timed out")
    } finally {
        timeout.cancel(false)
        connection.disconnect()
    }
}

private fun hasPdfStructure(file: File): Boolean {
    val size = file.length()
    if (size !in pdfMagic.size.toLong()..MAX_DOCUMENT_BYTES ||
        !file.inputStream().use { it.startsWith(pdfMagic) }) return false
    return RandomAccessFile(file, "r").use { pdf ->
        val tail = ByteArray(minOf(size, 1024).toInt())
        pdf.seek(size - tail.size)
        pdf.readFully(tail)
        val trailer = pdfTrailer.find(tail.toString(Charsets.US_ASCII)) ?: return@use false
        val xref = trailer.groupValues[1].toLongOrNull() ?: return@use false
        val trailerStart = size - tail.size + trailer.range.first
        if (xref !in pdfMagic.size.toLong() until trailerStart) return@use false
        val marker = ByteArray(minOf(trailerStart - xref, 64).toInt())
        pdf.seek(xref)
        pdf.readFully(marker)
        pdfCrossReference.containsMatchIn(marker.toString(Charsets.US_ASCII))
    }
}

private fun InputStream.copyBoundedTo(output: OutputStream? = null, limit: Long = MAX_DOCUMENT_BYTES): Long {
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
private const val MAX_EXPANDED_BYTES = 192 * 1024 * 1024L
private const val MAX_DOCX_ESTIMATE_BYTES = 8 * 1024 * 1024L
private const val MAX_DOCX_ESTIMATE_EXPANDED = 32 * 1024 * 1024L

internal fun docxEstimateBytes(context: Context, uri: Uri): ByteArray {
    require(uri.scheme == "content")
    val source = File.createTempFile("docx-estimate-", ".tmp", context.cacheDir)
    try {
        openOfficeInput(context, uri).use { input ->
            source.outputStream().use { input.copyBoundedTo(it, MAX_DOCX_ESTIMATE_BYTES) }
        }
        validateOpenXml(source, openXmlTypes.getValue("docx"), estimate = true)
        return source.readBytes()
    } finally {
        source.delete()
    }
}

private fun validateOpenXml(file: File, type: OfficeType, estimate: Boolean = false) {
    require(file.inputStream().use { it.startsWith(byteArrayOf(0x50, 0x4b, 0x03, 0x04)) })
    ZipFile(file).use { zip ->
        require(zip.size() <= 10_000)
        val entries = mutableSetOf<String>()
        val stream = zip.entries()
        val expandedLimit = if (estimate) MAX_DOCX_ESTIMATE_EXPANDED else MAX_EXPANDED_BYTES
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
            if (estimate && !entry.isDirectory) {
                val actual = zip.getInputStream(entry).use { it.copyBoundedTo(limit = expandedLimit - expanded) }
                require(actual == entry.size)
            }
            expanded += entry.size
        }
        var matchedMainPart = false
        zip.inspectXml("[Content_Types].xml", "Types", setOf(CONTENT_TYPES_NAMESPACE), true) { parser ->
            if (parser.depth == 2 && parser.name == "Override" && parser.namespace == CONTENT_TYPES_NAMESPACE &&
                parser.getAttributeValue(null, "PartName") == "/${type.part}"
            ) {
                val contentType = "application/vnd.openxmlformats-officedocument.${type.type}.main+xml"
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
                    require(!matchedRelationship && target == type.part && (mode == null || mode == "Internal"))
                    matchedRelationship = true
                }
            }
        }
        require(matchedRelationship)
        zip.inspectXml(type.part, type.root, setOf(
            "$OFFICE_NAMESPACE/${type.family}/2006/main",
            "$STRICT_OFFICE_NAMESPACE/${type.family}/main",
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

private const val FREE_SECTOR = -1
private const val END_OF_CHAIN = -2
private const val DIRECTORY_ENTRY_BYTES = 128
private const val MINI_SECTOR_BYTES = 64
private const val MINI_STREAM_CUTOFF = 4096
private val cfbSignature = byteArrayOf(
    0xd0.toByte(), 0xcf.toByte(), 0x11, 0xe0.toByte(), 0xa1.toByte(), 0xb1.toByte(), 0x1a, 0xe1.toByte(),
)

private fun validateLegacyOffice(file: File, extension: String) {
    if (!file.inputStream().use { it.startsWith(cfbSignature) }) {
        require(extension == "xls" && file.inputStream().buffered().use(::isUnencryptedBiff))
        return
    }
    RandomAccessFile(file, "r").use { source ->
        val headerBytes = ByteArray(512).also(source::readFully)
        require(headerBytes.copyOf(cfbSignature.size).contentEquals(cfbSignature))
        val header = ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN)
        val version = header.getShort(26).toInt()
        val sectorShift = header.getShort(30).toInt()
        require((version == 3 && sectorShift == 9) || (version == 4 && sectorShift == 12))
        require((header.getShort(28).toInt() and 0xffff) == 0xfffe && header.getShort(32).toInt() == 6)
        require(header.getInt(56) == MINI_STREAM_CUTOFF)
        val sectorBytes = 1 shl sectorShift
        require(source.length() % sectorBytes == 0L)
        val sectorCount = (source.length() / sectorBytes - 1).toInt()
        val fatCount = header.getInt(44)
        val difatCount = header.getInt(72)
        require(fatCount in 1 until sectorCount && difatCount in 0 until sectorCount)

        val sector = ByteBuffer.allocate(sectorBytes).order(ByteOrder.LITTLE_ENDIAN)
        fun readSector(index: Int) {
            require(index in 0 until sectorCount)
            source.seek((index + 1L) * sectorBytes)
            source.readFully(sector.array())
        }

        val allocationSectors = mutableSetOf<Int>()
        val fatSectors = mutableListOf<Int>()
        fun addFat(index: Int) {
            if (index == FREE_SECTOR) return
            require(index in 0 until sectorCount && allocationSectors.add(index) && fatSectors.size < fatCount)
            fatSectors.add(index)
        }

        for (offset in 76 until 512 step 4) addFat(header.getInt(offset))
        var nextDifat = header.getInt(68)
        repeat(difatCount) {
            require(allocationSectors.add(nextDifat))
            readSector(nextDifat)
            for (offset in 0 until sectorBytes - 4 step 4) addFat(sector.getInt(offset))
            nextDifat = sector.getInt(sectorBytes - 4)
        }
        require(nextDifat == END_OF_CHAIN && fatSectors.size == fatCount)
        val fat = IntArray(sectorCount)
        for ((index, fatSector) in fatSectors.withIndex()) {
            readSector(fatSector)
            val start = index * sectorBytes / 4
            for (offset in 0 until minOf(sectorBytes / 4, sectorCount - start)) {
                fat[start + offset] = sector.getInt(offset * 4)
            }
        }
        require(fatCount * (sectorBytes / 4) >= sectorCount)

        val directory = mutableListOf<Int>()
        var next = header.getInt(48)
        while (next != END_OF_CHAIN) {
            require(next in 0 until sectorCount && allocationSectors.add(next))
            directory.add(next)
            readSector(next)
            for (offset in 0 until sectorBytes step DIRECTORY_ENTRY_BYTES) {
                if (sector.get(offset + 66).toInt() == 0) continue
                val name = directoryName(sector, offset)
                require(
                    !name.equals("FileHeader", ignoreCase = true) &&
                        !name.equals("EncryptedPackage", ignoreCase = true) &&
                        !name.equals("EncryptionInfo", ignoreCase = true)
                )
            }
            next = fat[next]
        }
        require(directory.isNotEmpty() && (version == 3 || directory.size == header.getInt(40)))

        // The main stream must belong to the root storage, not a nested embedded Office object.
        readSector(directory.first())
        require(sector.get(66).toInt() == 5 && directoryName(sector, 0) == "Root Entry")
        val miniStart = sector.getInt(116)
        val miniSize = sector.getLong(120)
        val entriesPerSector = sectorBytes / DIRECTORY_ENTRY_BYTES
        val visited = BooleanArray(directory.size * entriesPerSector)
        val pending = ArrayDeque<Int>().apply { addLast(sector.getInt(76)) }
        var loadedSector = directory.first()
        val streams = mutableMapOf<String, Pair<Int, Long>>()
        while (pending.isNotEmpty()) {
            val index = pending.removeLast()
            if (index == FREE_SECTOR) continue
            require(index in 1 until visited.size && !visited[index])
            visited[index] = true
            val sectorId = directory[index / entriesPerSector]
            if (sectorId != loadedSector) {
                readSector(sectorId)
                loadedSector = sectorId
            }
            val offset = index % entriesPerSector * DIRECTORY_ENTRY_BYTES
            val type = sector.get(offset + 66).toInt()
            require(type == 1 || type == 2)
            if (type == 2) {
                val name = directoryName(sector, offset).lowercase(Locale.ROOT)
                val stream = sector.getInt(offset + 116) to sector.getLong(offset + 120)
                require(streams.put(name, stream) == null)
            }
            pending.addLast(sector.getInt(offset + 68))
            pending.addLast(sector.getInt(offset + 72))
        }

        fun readHeader(name: String, size: Int): ByteArray {
            val (start, length) = streams[name] ?: throw IOException("Missing Office stream")
            require(length in size.toLong()..MAX_DOCUMENT_BYTES && size <= MINI_SECTOR_BYTES)
            val offset = if (length >= MINI_STREAM_CUTOFF) {
                require(start in 0 until sectorCount && start !in allocationSectors)
                (start + 1L) * sectorBytes
            } else {
                val miniOffset = start.toLong() * MINI_SECTOR_BYTES
                require(start >= 0 && miniOffset + size <= miniSize && miniSize <= MAX_DOCUMENT_BYTES)
                var sectorId = miniStart
                val miniStreamSectors = mutableSetOf<Int>()
                repeat((miniOffset / sectorBytes).toInt()) {
                    require(sectorId in 0 until sectorCount && sectorId !in allocationSectors && miniStreamSectors.add(sectorId))
                    sectorId = fat[sectorId]
                }
                require(sectorId in 0 until sectorCount && sectorId !in allocationSectors && sectorId !in miniStreamSectors)
                (sectorId + 1L) * sectorBytes + miniOffset % sectorBytes
            }
            source.seek(offset)
            return ByteArray(size).also(source::readFully)
        }

        when (extension) {
            "doc" -> {
                val fib = ByteBuffer.wrap(readHeader("worddocument", 12)).order(ByteOrder.LITTLE_ENDIAN)
                require((fib.getShort(0).toInt() and 0xffff) == 0xa5ec)
                val flags = fib.getShort(10).toInt()
                require((flags and 0x8100) == 0)
                val table = if ((flags and 0x0200) != 0) "1table" else "0table"
                require((fib.getShort(2).toInt() and 0xffff) < 0x00c1 || table in streams)
            }
            "xls" -> {
                val name = if ("workbook" in streams) "workbook" else "book"
                val (start, length) = streams[name] ?: throw IOException("Missing Excel workbook")
                require(length in 8..MAX_DOCUMENT_BYTES)
                val workbook = if (length >= MINI_STREAM_CUTOFF) {
                    val chain = sectorChain(start, sectorLength(length, sectorBytes), fat, allocationSectors)
                    CompoundInput(source, length, sectorBytes) { index -> (chain[index] + 1L) * sectorBytes }
                } else {
                    require(miniSize in length..MAX_DOCUMENT_BYTES)
                    val miniFatCount = header.getInt(64)
                    require(miniFatCount in 1..sectorLength(miniSize, MINI_SECTOR_BYTES * (sectorBytes / 4)))
                    val miniFatSectors = sectorChain(header.getInt(60), miniFatCount, fat, allocationSectors)
                    val miniStream = sectorChain(miniStart, sectorLength(miniSize, sectorBytes), fat, allocationSectors)
                    val miniFat = IntArray(miniFatCount * (sectorBytes / 4))
                    for ((index, sectorId) in miniFatSectors.withIndex()) {
                        readSector(sectorId)
                        for (offset in 0 until sectorBytes / 4) {
                            miniFat[index * sectorBytes / 4 + offset] = sector.getInt(offset * 4)
                        }
                    }
                    val chain = sectorChain(start, sectorLength(length, MINI_SECTOR_BYTES), miniFat, mutableSetOf())
                    require(chain.all { (it + 1L) * MINI_SECTOR_BYTES <= miniSize })
                    CompoundInput(source, length, MINI_SECTOR_BYTES) { index ->
                        val offset = chain[index] * MINI_SECTOR_BYTES
                        (miniStream[offset / sectorBytes] + 1L) * sectorBytes + offset % sectorBytes
                    }
                }
                require(isUnencryptedBiff(workbook))
            }
            "ppt" -> {
                val user = readHeader("current user", 16)
                val presentation = readHeader("powerpoint document", 8)
                require(user[2] == 0xf6.toByte() && user[3] == 0x0f.toByte())
                require(user.copyOfRange(12, 16).contentEquals(byteArrayOf(0x5f, 0xc0.toByte(), 0x91.toByte(), 0xe3.toByte())))
                require(presentation[2] == 0xe8.toByte() && presentation[3] == 0x03.toByte())
            }
        }
    }
}

private fun sectorLength(size: Long, sectorBytes: Int): Int = ((size + sectorBytes - 1) / sectorBytes).toInt()

private fun sectorChain(start: Int, length: Int, table: IntArray, used: MutableSet<Int>): IntArray {
    require(length <= table.size)
    var next = start
    return IntArray(length) {
        require(next in table.indices && used.add(next))
        next.also { next = table[it] }
    }.also { require(next == END_OF_CHAIN) }
}

// Reads BIFF records across sector boundaries without materializing the workbook.
private class CompoundInput(
    private val source: RandomAccessFile,
    private val size: Long,
    private val sectorBytes: Int,
    private val sectorOffset: (Int) -> Long,
) : InputStream() {
    private val sector = ByteArray(sectorBytes)
    private var loaded = -1
    private var position = 0L

    override fun read(): Int {
        if (position >= size) return -1
        val index = (position / sectorBytes).toInt()
        if (index != loaded) {
            source.seek(sectorOffset(index))
            source.readFully(sector)
            loaded = index
        }
        return (sector[(position++ % sectorBytes).toInt()].toInt() and 0xff)
    }

    override fun skip(count: Long): Long = minOf(count.coerceAtLeast(0), size - position).also { position += it }
}

private fun isUnencryptedBiff(input: InputStream): Boolean {
    val bytes = ByteArray(8)
    for (index in bytes.indices) {
        val byte = input.read()
        if (byte < 0) return false
        bytes[index] = byte.toByte()
    }
    val header = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
    val length = header.getShort(2).toInt()
    if (header.getShort(0).toInt() !in setOf(0x0009, 0x0209, 0x0409, 0x0809) ||
        length !in 4..16 || header.getShort(6).toInt() !in setOf(0x0005, 0x0010) ||
        !skipRecord(input, length - 4)
    ) return false
    while (true) {
        for (index in 0..3) {
            val byte = input.read()
            if (byte < 0) return false
            bytes[index] = byte.toByte()
        }
        val type = header.getShort(0).toInt() and 0xffff
        val size = header.getShort(2).toInt() and 0xffff
        if (type == 0x002f) return false // FILEPASS means the workbook is encrypted.
        if (type == 0x000a) return size == 0
        if (!skipRecord(input, size)) return false
    }
}

private fun skipRecord(input: InputStream, size: Int): Boolean {
    if (size == 0) return true
    // FileInputStream.skip may seek past EOF. Require the last byte to exist.
    var remaining = size.toLong() - 1
    while (remaining > 0) {
        val skipped = input.skip(remaining)
        if (skipped > 0) remaining -= skipped
        else if (input.read() >= 0) remaining--
        else return false
    }
    return input.read() >= 0
}

private fun directoryName(sector: ByteBuffer, offset: Int): String {
    val length = sector.getShort(offset + 64).toInt()
    require(length in 2..64 && length % 2 == 0 && sector.getShort(offset + length - 2).toInt() == 0)
    return String(sector.array(), offset, length - 2, Charsets.UTF_16LE)
}
