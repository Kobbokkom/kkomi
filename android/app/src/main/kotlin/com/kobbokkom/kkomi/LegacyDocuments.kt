package com.kobbokkom.kkomi

import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileNotFoundException

internal fun restoreLegacyDocuments(context: Context, entries: List<*>): List<Map<String, String>> {
    val cache = File(context.filesDir, "file_cache").canonicalFile
    val authority = "${context.packageName}.documents"
    val persisted = context.contentResolver.persistedUriPermissions
        .filter { it.isReadPermission }.map { it.uri }.toSet()
    return entries.asSequence().mapNotNull { entry ->
        val record = entry as? Map<*, *> ?: return@mapNotNull null
        val path = record["path"] as? String ?: return@mapNotNull null
        val name = record["name"] as? String ?: return@mapNotNull null
        val extension = record["extension"] as? String ?: return@mapNotNull null
        val openedAt = record["openedAt"] as? String ?: return@mapNotNull null
        val uri = runCatching {
            val parsed = Uri.parse(path)
            when (parsed.scheme) {
                "content" -> parsed.takeIf(persisted::contains)
                null, "file" -> {
                    val localPath = if (parsed.scheme == null) path else parsed.path
                    val file = localPath?.let { File(it).canonicalFile } ?: return@runCatching null
                    if (file.parentFile != cache || !file.isFile ||
                        !file.canRead() || file.length() > MAX_DOCUMENT_BYTES
                    ) return@runCatching null
                    FileProvider.getUriForFile(context, authority, file, name)
                }
                else -> null
            }
        }.getOrNull() ?: return@mapNotNull null
        mapOf("uri" to uri.toString(), "name" to name, "extension" to extension, "openedAt" to openedAt)
    }.distinctBy {
        val uri = Uri.parse(it.getValue("uri"))
        if (uri.authority == authority) uri.buildUpon().clearQuery().build() else uri
    }
        .take(10).toList()
}

internal fun findMissingRecentDocuments(context: Context, entries: List<*>): List<String> {
    val ownAuthority = "${context.packageName}.documents"
    val resolver = context.contentResolver
    val readable = resolver.persistedUriPermissions.filter { it.isReadPermission }.map { it.uri }.toSet()
    val primaryMounted = !Environment.isExternalStorageRemovable() &&
        Environment.getExternalStorageState() in setOf(Environment.MEDIA_MOUNTED, Environment.MEDIA_MOUNTED_READ_ONLY)
    return entries.asSequence().filterIsInstance<String>().take(10).filter { raw ->
        val uri = Uri.parse(raw)
        if (uri.scheme != "content") return@filter false
        when {
            uri.authority == ownAuthority -> isMissingPrivateDocument(context, uri)
            primaryMounted && uri in readable && isPrimaryStorageDocument(context, uri) -> {
                val descriptor = try {
                    resolver.openFileDescriptor(uri, "r")
                } catch (_: FileNotFoundException) {
                    // These mounted local document IDs are authoritative about missing files.
                    return@filter true
                } catch (_: Exception) {
                    return@filter false
                }
                runCatching { descriptor?.close() }
                false
            }
            else -> false
        }
    }.toList()
}

private fun isMissingPrivateDocument(context: Context, uri: Uri): Boolean {
    val parts = uri.pathSegments
    if (parts.size != 2) return false
    val root = when (parts[0]) {
        "documents" -> "documents"
        "legacy_documents" -> "file_cache"
        else -> return false
    }
    return try {
        val directory = File(context.filesDir, root).canonicalFile
        val file = File(directory, parts[1]).canonicalFile
        if (file.parentFile != directory) return false
        Os.stat(file.path)
        false
    } catch (error: ErrnoException) {
        error.errno == OsConstants.ENOENT
    } catch (_: Exception) {
        false
    }
}

private fun isPrimaryStorageDocument(context: Context, uri: Uri): Boolean = runCatching {
    if (!DocumentsContract.isDocumentUri(context, uri)) return false
    val id = DocumentsContract.getDocumentId(uri)
    when (uri.authority) {
        "com.android.externalstorage.documents" -> id.startsWith("primary:")
        "com.android.providers.downloads.documents" -> {
            val path = id.takeIf { it.startsWith("raw:") }?.removePrefix("raw:") ?: return false
            @Suppress("DEPRECATION")
            val primary = Environment.getExternalStorageDirectory().canonicalFile
            File(path).canonicalPath.startsWith(primary.path + File.separator)
        }
        else -> false
    }
}.getOrDefault(false)
