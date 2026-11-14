package com.kobbokkom.kkomi

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream

private const val ORIGIN = "https://appassets.androidplatform.net"
private const val VIEWER_URL = "$ORIGIN/assets/viewer.html"

internal class DocumentWebViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val document = args as Map<*, *>
        return DocumentWebView(
            context,
            MethodChannel(messenger, "kkomi/viewer/$viewId"),
            Uri.parse(document["uri"] as String),
            document["extension"] as String,
            document["name"] as String,
            document["viewerStrings"] as? String ?: "{}",
        )
    }
}

private class DocumentWebView(
    private val context: Context,
    private val channel: MethodChannel,
    private val documentUri: Uri,
    private val extension: String,
    private val name: String,
    private val viewerStrings: String,
) : PlatformView {
    private val webView = WebView(context)
    private val labels by lazy { runCatching { JSONObject(viewerStrings) }.getOrNull() }
    private var rendererGone = false
    private val handler = Handler(Looper.getMainLooper())
    private var startupPending = false
    private val startupTimeout = Runnable { failStartup() }
    private var hwpPrintResult: MethodChannel.Result? = null
    private var printing = false
    private var hwpCanPrint = false
    private var slideMedia: PrintAttributes.MediaSize? = null
    private val hwpPrintTimeout = Runnable { failHwpPrint("PDF를 준비하는 데 시간이 너무 오래 걸립니다.") }

    init {
        val loader = WebViewAssetLoader.Builder().addPathHandler("/assets/") { path ->
            try {
                if (path.split('/').any { it == "." || it == ".." }) return@addPathHandler emptyResponse(404, "Not found")
                val lookup = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset("assets/$path")
                val mime = when (path.substringAfterLast('.')) {
                    "html" -> "text/html"
                    "js", "mjs" -> "text/javascript"
                    "css" -> "text/css"
                    "wasm" -> "application/wasm"
                    else -> "application/octet-stream"
                }
                WebResourceResponse(mime, null, context.assets.open(lookup))
            } catch (_: IOException) {
                emptyResponse(404, "Not found")
            }
        }.build()

        webView.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            blockNetworkLoads = true
            setSupportZoom(true)
            builtInZoomControls = true
            displayZoomControls = false
            useWideViewPort = true
            loadWithOverviewMode = true
        }
        webView.setBackgroundColor(android.graphics.Color.rgb(239, 239, 238))
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                request.url.toString() != VIEWER_URL

            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                val url = request.url
                if (url.scheme != "https" || url.host != "appassets.androidplatform.net" ||
                    url.port != -1 || request.method != "GET") return emptyResponse(403, "Forbidden")
                if (url.path == "/document" && url.query == null) {
                    return try {
                        if (documentUri.scheme != "content") return emptyResponse(403, "Forbidden")
                        val input = context.contentResolver.openInputStream(documentUri)
                            ?: return emptyResponse(404, "Not found")
                        WebResourceResponse("application/octet-stream", null, BoundedDocumentStream(input))
                    } catch (_: Exception) {
                        emptyResponse(404, "Not found")
                    }
                }
                return loader.shouldInterceptRequest(url) ?: emptyResponse(404, "Not found")
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) failStartup()
            }

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                rendererGone = true
                finishStartup()
                failHwpPrint("PDF를 준비할 수 없습니다.")
                channel.invokeMethod("error", "문서 뷰어가 종료됐습니다. 파일을 다시 열어 주세요.")
                (view.parent as? android.view.ViewGroup)?.removeView(view)
                view.destroy()
                return true
            }
        }

        val canReport = WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)
        if (canReport) {
            WebViewCompat.addWebMessageListener(webView, "Kkomi", setOf(ORIGIN)) { _, message, _, main, _ ->
                if (!main) return@addWebMessageListener
                val data = try {
                    JSONObject(message.data ?: return@addWebMessageListener)
                } catch (_: Exception) {
                    return@addWebMessageListener
                }
                when (val event = data.optString("event")) {
                    "viewerReady" -> if (finishStartup()) {
                        val fileType = JSONObject.quote(extension)
                        val localizedStrings = JSONObject.quote(viewerStrings)
                        webView.evaluateJavascript("window.openDocument($fileType, $localizedStrings); true") { started ->
                            if (started != "true" && !rendererGone) {
                                channel.invokeMethod("error", "문서 뷰어를 시작할 수 없습니다.")
                            }
                        }
                    }
                    "ready", "page" -> channel.invokeMethod(event, data.optInt("value"))
                    "error" -> channel.invokeMethod(event, data.optString("value"))
                    "password" -> channel.invokeMethod(event, data.optBoolean("value"))
                    "canPrint" -> {
                        hwpCanPrint = data.optBoolean("value")
                        channel.invokeMethod(event, hwpCanPrint)
                    }
                    "printReady" -> {
                        val dimensions = data.optJSONObject("value")
                        val width = dimensions?.optDouble("width") ?: 0.0
                        val height = dimensions?.optDouble("height") ?: 0.0
                        if (width > 0 && height > 0) printHwp(width > height)
                        else failHwpPrint("PDF를 준비할 수 없습니다.")
                    }
                    "printError" -> failHwpPrint(data.optString("value", "PDF를 준비할 수 없습니다."))
                    "printMedia" -> {
                        val dimensions = data.optJSONObject("value")
                        val width = dimensions?.optInt("width") ?: 0
                        val height = dimensions?.optInt("height") ?: 0
                        if (extension in setOf("ppt", "pptx") && width in 1000..40000 && height in 1000..40000) {
                            val label = labels?.optString("slideSize", "슬라이드 크기") ?: "슬라이드 크기"
                            slideMedia = PrintAttributes.MediaSize("kkomi-slide", label, width, height)
                        }
                    }
                    "matches" -> {
                        val value = data.optJSONObject("value") ?: return@addWebMessageListener
                        channel.invokeMethod(event, mapOf(
                            "request" to value.optInt("request"),
                            "count" to value.optInt("count"),
                            "current" to value.optInt("current"),
                        ))
                    }
                }
            }
        }
        channel.setMethodCallHandler { call, result ->
            if (rendererGone) {
                result.success(null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "start" -> {
                    if (canReport) {
                        handler.removeCallbacks(startupTimeout)
                        startupPending = true
                        handler.postDelayed(startupTimeout, 10_000L)
                        webView.loadUrl(VIEWER_URL)
                    } else {
                        channel.invokeMethod("error", "Android System WebView를 업데이트한 뒤 다시 열어 주세요.")
                    }
                }
                "find" -> {
                    val query = JSONObject.quote(call.argument<String>("query").orEmpty())
                    val request = call.argument<Int>("request") ?: 0
                    webView.evaluateJavascript("window.findInDocument($query, $request)", null)
                }
                "match" -> {
                    val step = call.arguments as? Int ?: 1
                    webView.evaluateJavascript("window.moveToMatch($step)", null)
                }
                "page" -> {
                    val index = call.arguments as? Int ?: 0
                    webView.evaluateJavascript("window.goToPage($index)", null)
                }
                "imageFit" -> {
                    val fit = call.arguments as? Boolean ?: true
                    webView.evaluateJavascript("window.setImageFit($fit)", null)
                }
                "password" -> {
                    val password = call.arguments as? String
                    val value = password?.let(JSONObject::quote) ?: "null"
                    webView.evaluateJavascript("window.submitPassword($value)", null)
                }
                "print" -> {
                    if (printing || hwpPrintResult != null) {
                        result.error("print", "이미 PDF를 준비하고 있습니다.", null)
                        return@setMethodCallHandler
                    }
                    if (extension == "hwp" || extension == "hwpx") {
                        if (!hwpCanPrint) {
                            result.error("print", "이 문서는 PDF로 저장할 수 없습니다.", null)
                        } else {
                            hwpPrintResult = result
                            handler.postDelayed(hwpPrintTimeout, 90_000)
                            webView.evaluateJavascript("window.prepareHwpPrint()", null)
                        }
                        return@setMethodCallHandler
                    } else if (extension in setOf("txt", "csv", "doc", "docx", "ppt", "pptx", "xls", "xlsx")) {
                        val isSlide = extension in setOf("ppt", "pptx")
                        val paper = if (isSlide) {
                            slideMedia ?: PrintAttributes.MediaSize.ISO_A4.asLandscape()
                        } else {
                            PrintAttributes.MediaSize.ISO_A4
                        }
                        val attributes = PrintAttributes.Builder().setMediaSize(paper).apply {
                            if (slideMedia != null) setMinMargins(PrintAttributes.Margins.NO_MARGINS)
                        }.build()
                        try {
                            startPrint(attributes, fitSlides = isSlide)
                        } catch (_: RuntimeException) {
                            result.error("print", "PDF를 저장할 수 없습니다.", null)
                            return@setMethodCallHandler
                        }
                    }
                }
                else -> {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
            }
            result.success(null)
        }
    }

    private fun startPrint(attributes: PrintAttributes, fitSlides: Boolean = false, onFinish: () -> Unit = {}) {
        val title = name.substringBeforeLast('.').ifBlank { labels?.optString("document", "문서") ?: "문서" }
        val manager = context.getSystemService(Context.PRINT_SERVICE) as PrintManager
        val adapter = printAdapter(webView.createPrintDocumentAdapter(title), fitSlides) {
            printing = false
            onFinish()
        }
        printing = true
        try {
            checkNotNull(manager.print(title, adapter, attributes))
        } catch (error: RuntimeException) {
            printing = false
            throw error
        }
    }

    private fun printAdapter(
        delegate: PrintDocumentAdapter,
        fitSlides: Boolean,
        onFinish: () -> Unit,
    ): PrintDocumentAdapter = object : PrintDocumentAdapter() {
        override fun onStart() = delegate.onStart()

        override fun onLayout(
            oldAttributes: PrintAttributes, newAttributes: PrintAttributes,
            signal: CancellationSignal, callback: LayoutResultCallback, extras: Bundle?,
        ) {
            val media = newAttributes.mediaSize
            val margins = newAttributes.minMargins
            if (!fitSlides || media == null || margins == null || rendererGone) {
                delegate.onLayout(oldAttributes, newAttributes, signal, callback, extras)
                return
            }
            val width = (media.widthMils - margins.leftMils - margins.rightMils).coerceAtLeast(1) * 0.096
            val height = (media.heightMils - margins.topMils - margins.bottomMils).coerceAtLeast(1) * 0.096
            webView.evaluateJavascript("window.fitOfficeSlides?.($width, $height)") {
                if (signal.isCanceled) callback.onLayoutCancelled()
                else if (rendererGone) {
                    callback.onLayoutFailed(labels?.optString("pdfPreparationFailed", "PDF를 준비할 수 없습니다."))
                }
                else delegate.onLayout(oldAttributes, newAttributes, signal, callback, extras)
            }
        }

        override fun onWrite(
            pages: Array<PageRange>, target: ParcelFileDescriptor,
            signal: CancellationSignal, callback: WriteResultCallback,
        ) = delegate.onWrite(pages, target, signal, callback)

        override fun onFinish() {
            try {
                delegate.onFinish()
            } finally {
                onFinish.invoke()
            }
        }
    }

    private fun printHwp(landscape: Boolean) {
        val result = hwpPrintResult ?: return
        handler.removeCallbacks(hwpPrintTimeout)
        try {
            val paper = PrintAttributes.MediaSize.ISO_A4
            val attributes = PrintAttributes.Builder()
                .setMediaSize(if (landscape) paper.asLandscape() else paper)
                .setMinMargins(PrintAttributes.Margins.NO_MARGINS).build()
            startPrint(attributes, onFinish = ::releaseHwpPrint)
            hwpPrintResult = null
            result.success(null)
        } catch (_: RuntimeException) {
            failHwpPrint("PDF를 저장할 수 없습니다.")
        }
    }

    private fun releaseHwpPrint() {
        if (!rendererGone) webView.evaluateJavascript("window.releaseHwpPrint()", null)
    }

    private fun failHwpPrint(message: String) {
        val result = hwpPrintResult ?: return
        hwpPrintResult = null
        handler.removeCallbacks(hwpPrintTimeout)
        releaseHwpPrint()
        result.error("print", message, null)
    }

    private fun finishStartup(): Boolean {
        if (!startupPending) return false
        startupPending = false
        handler.removeCallbacks(startupTimeout)
        return true
    }

    private fun failStartup() {
        if (finishStartup()) channel.invokeMethod("error", "문서 뷰어를 시작할 수 없습니다.")
    }

    override fun getView() = webView

    override fun dispose() {
        channel.setMethodCallHandler(null)
        finishStartup()
        failHwpPrint("PDF 준비가 취소됐습니다.")
        if (!rendererGone) {
            rendererGone = true
            webView.stopLoading()
            webView.destroy()
        }
    }
}

private fun emptyResponse(status: Int, reason: String) =
    WebResourceResponse("text/plain", "UTF-8", status, reason, emptyMap(), ByteArrayInputStream(byteArrayOf()))

private class BoundedDocumentStream(source: InputStream) : FilterInputStream(source) {
    private var remaining = MAX_DOCUMENT_BYTES

    override fun read(): Int {
        val byte = super.read()
        if (byte != -1 && --remaining < 0) throw IOException("Document exceeds size limit")
        return byte
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        val read = super.read(buffer, offset, minOf(length.toLong(), remaining + 1).toInt())
        if (read > 0) remaining -= read
        if (remaining < 0) throw IOException("Document exceeds size limit")
        return read
    }
}
