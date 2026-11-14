package com.kobbokkom.kkomi

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

private const val PICK_DOCUMENT = 6401
private const val SAVE_CONVERTED_PDF = 6402
private const val EXTERNAL_STORAGE_PROVIDER = "com.android.externalstorage.documents"
internal const val MAX_DOCUMENT_BYTES = 64L * 1024 * 1024

private typealias DocumentResult = (Map<String, String>?, String?) -> Unit

private val documentTypes = mapOf(
    "hwp" to "application/x-hwp",
    "hwpx" to "application/vnd.hancom.hwpx",
    "pdf" to "application/pdf",
    "doc" to "application/msword",
    "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls" to "application/vnd.ms-excel",
    "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "ppt" to "application/vnd.ms-powerpoint",
    "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "txt" to "text/plain",
    "csv" to "text/csv",
    "jpg" to "image/jpeg",
    "jpeg" to "image/jpeg",
    "png" to "image/png",
    "gif" to "image/gif",
    "webp" to "image/webp",
    "bmp" to "image/bmp",
    "avif" to "image/avif",
)
private val documentTypeAliases = mapOf(
    "application/csv" to "csv",
    "application/haansofthwp" to "hwp",
    "application/vnd.hancom.hwp" to "hwp",
    "application/x-hwp" to "hwp",
    "application/hwp" to "hwp",
    "application/hwpx" to "hwpx",
    "application/x-hwpx" to "hwpx",
    "application/hwp+zip" to "hwpx",
    "application/vnd.hancom.hwpx" to "hwpx",
    "image/x-bmp" to "bmp",
    "image/x-ms-bmp" to "bmp",
)

class MainActivity : FlutterActivity() {
    private val documents = Executors.newSingleThreadExecutor()
    private val conversions = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null
    private var picker: DocumentResult? = null
    private var pdfSave: Pair<Uri, MethodChannel.Result>? = null
    private var discardAfterSave: Uri? = null
    private var listening = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "kkomi/viewer", DocumentWebViewFactory(messenger)
        )
        channel = MethodChannel(messenger, "kkomi/documents").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> {
                        listening = true
                        result.success(null)
                        handleIntent(intent)
                    }
                    "pick" -> pickDocument { document, error ->
                        if (error == null) result.success(document) else result.error("document", error, null)
                    }
                    "officeConverterAvailable" -> {
                        val endpoint = call.arguments as? String
                        result.success(endpoint != null && officeConverterAvailable(this@MainActivity, endpoint))
                    }
                    "cachedOfficePdf" -> {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        val extension = call.argument<String>("extension")
                        val endpoint = call.argument<String>("endpoint")
                        if (uri?.scheme != "content" || extension == null || endpoint == null) {
                            result.success(null)
                        } else {
                            conversions.execute {
                                val pdf = runCatching {
                                    cachedOfficePdf(this@MainActivity, uri, extension, endpoint)
                                }.getOrNull()
                                runOnUiThread {
                                    if (isDestroyed) {
                                        if (pdf != null) discardConvertedPdf(pdf)
                                    } else {
                                        result.success(pdf?.toString())
                                    }
                                }
                            }
                        }
                    }
                    "docxEstimateBytes" -> {
                        val uri = (call.arguments as? String)?.let(Uri::parse)
                        if (uri?.scheme != "content") {
                            result.success(null)
                        } else {
                            conversions.execute {
                                val bytes = runCatching { docxEstimateBytes(this@MainActivity, uri) }.getOrNull()
                                runOnUiThread { if (!isDestroyed) result.success(bytes) }
                            }
                        }
                    }
                    "convertOffice" -> {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        val extension = call.argument<String>("extension")
                        val endpoint = call.argument<String>("endpoint")
                        val token = call.argument<String>("token")
                        if (uri?.scheme != "content" || extension == null || endpoint == null) {
                            result.error("conversion", "변환에 필요한 문서 정보가 없습니다.", null)
                        } else {
                            conversions.execute {
                                val pdf = runCatching {
                                    convertOffice(this@MainActivity, uri, extension, endpoint, token)
                                }.getOrNull()
                                runOnUiThread {
                                    if (isDestroyed) {
                                        if (pdf != null) discardConvertedPdf(pdf)
                                    } else if (pdf == null) {
                                        result.error("conversion", "서버에서 PDF로 변환할 수 없습니다.", null)
                                    } else {
                                        result.success(pdf.toString())
                                    }
                                }
                            }
                        }
                    }
                    "convertLocalText" -> {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        val extension = call.argument<String>("extension")
                        val name = call.argument<String>("name")
                        if (uri?.scheme != "content" || extension !in setOf("txt", "csv") || name == null) {
                            result.error("conversion", "변환에 필요한 문서 정보가 없습니다.", null)
                        } else {
                            conversions.execute {
                                val pdf = runCatching {
                                    val file = convertTextPdf(this@MainActivity, uri, requireNotNull(extension), name)
                                    FileProvider.getUriForFile(this@MainActivity, "$packageName.documents", file)
                                }.getOrNull()
                                runOnUiThread {
                                    if (isDestroyed) {
                                        if (pdf != null) discardConvertedPdf(pdf)
                                    } else if (pdf == null) {
                                        result.error("conversion", "문서를 PDF로 변환할 수 없습니다.", null)
                                    } else {
                                        result.success(pdf.toString())
                                    }
                                }
                            }
                        }
                    }
                    "saveConvertedPdf" -> saveConvertedPdf(
                        call.argument<String>("uri")?.let(Uri::parse),
                        call.argument<String>("name").orEmpty(), result
                    )
                    "discardConvertedPdf" -> {
                        val uri = (call.arguments as? String)?.let(Uri::parse)
                        if (uri != null) {
                            if (uri == pdfSave?.first) discardAfterSave = uri
                            else documents.execute { discardConvertedPdf(uri) }
                        }
                        result.success(null)
                    }
                    "restoreLegacyDocuments" -> {
                        val entries = call.arguments as? List<*> ?: emptyList<Any>()
                        documents.execute {
                            val restored = runCatching { restoreLegacyDocuments(this@MainActivity, entries) }
                            runOnUiThread {
                                restored.fold(
                                    onSuccess = { result.success(it) },
                                    onFailure = { result.error("migration", "기존 문서 기록을 읽을 수 없습니다.", null) },
                                )
                            }
                        }
                    }
                    "findMissingRecentDocuments" -> {
                        val entries = call.arguments as? List<*> ?: emptyList<Any>()
                        documents.execute {
                            val missing = runCatching { findMissingRecentDocuments(this@MainActivity, entries) }
                                .getOrDefault(emptyList())
                            runOnUiThread { if (!isDestroyed) result.success(missing) }
                        }
                    }
                    "share", "openExternal" -> {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        val mime = call.argument<String>("extension")?.let(documentTypes::get)
                        if (uri?.scheme != "content" || mime == null) {
                            result.error("document", "문서 정보가 올바르지 않습니다.", null)
                        } else {
                            shareOrOpen(uri, mime, call.method == "share", result)
                        }
                    }
                    "forget" -> {
                        call.argument<String>("uri")?.let { raw ->
                            val uri = Uri.parse(raw)
                            documents.execute { runCatching { forgetDocument(uri) } }
                            conversions.execute { runCatching { forgetOfficePdf(this@MainActivity, uri) } }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun pickDocument(initialUri: Uri? = null, result: DocumentResult) {
        if (picker != null) {
            result(null, null)
            return
        }
        picker = result
        try {
            // Providers often label HWP as octet-stream. Validate the name after selection.
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                if (Build.VERSION.SDK_INT >= 26 && initialUri != null) {
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri)
                }
            }, PICK_DOCUMENT)
        } catch (_: android.content.ActivityNotFoundException) {
            picker = null
            result(null, "파일 선택기를 열 수 없습니다.")
        }
    }

    @Deprecated("Called by Android's document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SAVE_CONVERTED_PDF) {
            val (source, result) = pdfSave ?: return
            pdfSave = null
            val shouldDiscard = discardAfterSave == source
            discardAfterSave = null
            val target = data?.data
            if (resultCode != Activity.RESULT_OK || target == null) {
                if (shouldDiscard) documents.execute { discardConvertedPdf(source) }
                result.success(null)
            } else {
                documents.execute {
                    val saved = runCatching {
                        val input = contentResolver.openInputStream(source) ?: error("Missing PDF")
                        input.use {
                            val output = contentResolver.openOutputStream(target, "wt") ?: error("Missing destination")
                            output.use(input::copyTo)
                        }
                    }.isSuccess
                    if (shouldDiscard) discardConvertedPdf(source)
                    runOnUiThread {
                        if (saved) result.success(null)
                        else result.error("save", "PDF를 저장할 수 없습니다.", null)
                    }
                }
            }
            return
        }
        if (requestCode != PICK_DOCUMENT) return
        val result = picker ?: return
        picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result(null, null)
            return
        }
        importDocument(uri, data.type, result)
    }

    private fun isConvertedPdf(uri: Uri): Boolean =
        uri.scheme == "content" && uri.authority == "$packageName.documents" &&
            uri.pathSegments.firstOrNull() == "converted"

    private fun discardConvertedPdf(uri: Uri) {
        if (isConvertedPdf(uri)) runCatching { contentResolver.delete(uri, null, null) }
    }

    private fun saveConvertedPdf(uri: Uri?, name: String, result: MethodChannel.Result) {
        if (uri == null || !isConvertedPdf(uri) || pdfSave != null) {
            result.error("save", "PDF를 저장할 수 없습니다.", null)
            return
        }
        pdfSave = uri to result
        try {
            val base = name.substringBeforeLast('.').ifBlank { "Kkomi" }
            startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/pdf"
                putExtra(Intent.EXTRA_TITLE, "$base.pdf")
            }, SAVE_CONVERTED_PDF)
        } catch (_: android.content.ActivityNotFoundException) {
            pdfSave = null
            result.error("save", "PDF 저장 위치를 선택할 수 없습니다.", null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (listening) handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val uri = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                val stream = intent.getParcelableExtra<android.os.Parcelable>(Intent.EXTRA_STREAM) as? Uri
                stream ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
            }
            else -> null
        } ?: return
        setIntent(Intent(Intent.ACTION_MAIN))
        val report: DocumentResult = { document, error ->
            if (document != null) channel?.invokeMethod("open", document)
            else if (error != null) channel?.invokeMethod("openError", error)
        }
        if (uri.scheme == "file") {
            openLegacyFile(uri, report)
        } else {
            importDocument(uri, intent?.type, report)
        }
    }

    private fun openLegacyFile(uri: Uri, report: DocumentResult) {
        val path = uri.path
        if (!uri.authority.isNullOrEmpty() || path == null || !path.startsWith('/') || '\u0000' in path ||
            path.split('/').any { it == "." || it == ".." } ||
            path.substringAfterLast('.').lowercase() !in documentTypes
        ) {
            report(null, "지원하지 않는 파일 형식입니다.")
            return
        }
        val documentId = legacyDocumentId(path)
        val documentUri = documentId?.let { DocumentsContract.buildDocumentUri(EXTERNAL_STORAGE_PROVIDER, it) }
        val folder = documentId?.substringBeforeLast('/', documentId.substringBefore(':') + ":")
            ?.let { DocumentsContract.buildDocumentUri(EXTERNAL_STORAGE_PROVIDER, it) }
        if (documentUri == null || contentResolver.persistedUriPermissions.none { it.isReadPermission && it.uri == documentUri }) {
            pickDocument(folder, report)
            return
        }
        importDocument(documentUri, null) { document, error ->
            if (error == null) report(document, null)
            else pickDocument(folder, report)
        }
    }

    private fun legacyDocumentId(path: String): String? {
        @Suppress("DEPRECATION")
        val primary = Environment.getExternalStorageDirectory().absolutePath
        for (root in listOf(primary, "/sdcard", "/storage/self/primary")) {
            if (path.startsWith("$root/")) return "primary:${path.removePrefix("$root/")}"
        }
        if (Build.VERSION.SDK_INT >= 30) {
            for (volume in getSystemService(StorageManager::class.java).storageVolumes) {
                val root = volume.directory?.absolutePath ?: continue
                if (path.startsWith("$root/")) {
                    val id = if (volume.isPrimary) "primary" else volume.uuid ?: continue
                    return "$id:${path.removePrefix("$root/")}"
                }
            }
        }
        return null
    }

    private fun importDocument(
        uri: Uri,
        mime: String?,
        callback: DocumentResult,
    ) {
        documents.execute {
            val document = runCatching { readDocument(uri, mime) }
            runOnUiThread {
                if (isDestroyed) return@runOnUiThread
                callback(
                    document.getOrNull(),
                    document.exceptionOrNull()?.let { error ->
                        (error as? DocumentException)?.message ?: "파일을 읽을 수 없습니다."
                    },
                )
            }
        }
    }

    private fun readDocument(uri: Uri, mime: String?): Map<String, String> {
        if (uri.scheme != "content") throw DocumentException("이 파일 위치를 열 수 없습니다.")
        val (name, size) = contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null
        )?.use { cursor ->
            if (!cursor.moveToFirst()) {
                null
            } else {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                val name = if (nameIndex >= 0) cursor.getString(nameIndex) else null
                val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else null
                name to size
            }
        } ?: (null to null)
        val type = contentResolver.getType(uri)?.takeUnless { it == "application/octet-stream" } ?: mime
        val extension = (name ?: uri.lastPathSegment)?.substringAfterLast('.', "")?.lowercase()
            ?.takeIf(documentTypes::containsKey)
            ?: documentTypeAliases[type]
            ?: documentTypes.entries.firstOrNull { it.value == type }?.key
            ?: throw DocumentException("지원하지 않는 파일 형식입니다.")
        if (size != null && size > MAX_DOCUMENT_BYTES) throw DocumentException("64MB 이하의 문서를 열 수 있습니다.")
        val displayName = name?.takeIf(String::isNotBlank) ?: "Kkomi.$extension"
        val storedUri = if (uri.authority == "$packageName.documents") {
            uri
        } else {
            try {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                uri
            } catch (_: SecurityException) {
                copySharedDocument(uri, extension, displayName)
            }
        }
        return mapOf("uri" to storedUri.toString(), "name" to displayName, "extension" to extension)
    }

    private fun copySharedDocument(uri: Uri, extension: String, displayName: String): Uri {
        val directory = File(filesDir, "documents").apply { mkdirs() }
        val file = File(directory, "${UUID.randomUUID()}.$extension")
        try {
            val input = contentResolver.openInputStream(uri) ?: throw DocumentException("파일을 읽을 수 없습니다.")
            input.use { source ->
                file.outputStream().use { target ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var total = 0L
                    while (true) {
                        val read = source.read(buffer)
                        if (read == -1) break
                        total += read
                        if (total > MAX_DOCUMENT_BYTES) throw DocumentException("64MB 이하의 문서를 열 수 있습니다.")
                        target.write(buffer, 0, read)
                    }
                }
            }
            return FileProvider.getUriForFile(this, "$packageName.documents", file, displayName)
        } catch (error: Exception) {
            file.delete()
            throw error
        }
    }

    private fun forgetDocument(uri: Uri) {
        if (uri.authority == "$packageName.documents") {
            if (uri.pathSegments.firstOrNull() == "documents") {
                contentResolver.delete(uri, null, null)
            }
        } else {
            try {
                contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: SecurityException) {
                // Access may already have been revoked by the provider.
            }
        }
    }

    private fun shareOrOpen(uri: Uri, mime: String, share: Boolean, result: MethodChannel.Result) {
        val request = if (share) {
            Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, uri)
        } else {
            Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).apply {
                // Exclude our own viewer from the targets.
                val viewer = packageManager.queryIntentActivities(this, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
                    .firstOrNull { it.activityInfo.packageName != packageName &&
                        it.activityInfo.packageName != "com.kobbokkom.kkomi" &&
                        !it.activityInfo.packageName.startsWith("com.kobbokkom.kkomi.preview") }
                if (viewer == null) {
                    result.error("viewer", "이 형식을 열 수 있는 다른 앱이 설치되어 있지 않습니다.", null)
                    return
                }
                setClassName(viewer.activityInfo.packageName, viewer.activityInfo.name)
            }
        }
        request.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        request.clipData = android.content.ClipData.newRawUri("document", uri)
        try {
            startActivity(if (share) Intent.createChooser(request, null) else request)
            result.success(null)
        } catch (_: Exception) {
            result.error("viewer", "문서를 다른 앱으로 열 수 없습니다.", null)
        }
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        documents.shutdown()
        conversions.shutdown()
        super.onDestroy()
    }
}

private class DocumentException(message: String) : Exception(message)
