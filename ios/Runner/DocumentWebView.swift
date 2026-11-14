import Flutter
import ImageIO
import UniformTypeIdentifiers
import UIKit
import WebKit

private let viewerURL = URL(string: "kkomi://local/assets/viewer.html")!
private let maxDocumentBytes = 64 * 1024 * 1024
// Workers have their own policy even when the main document limits network access.
private let workerContentPolicy = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self'"

final class DocumentWebViewFactory: NSObject, FlutterPlatformViewFactory {
  private let registrar: FlutterPluginRegistrar

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    let document = args as? [String: String] ?? [:]
    let file = document["uri"].flatMap { try? DocumentAccess.importedFile($0) }
    let channel = FlutterMethodChannel(name: "kkomi/viewer/\(viewId)", binaryMessenger: registrar.messenger())
    let assetKey = registrar.lookupKey(forAsset: "assets/viewer.html") as NSString
    let assets = Bundle.main.url(forResource: assetKey.deletingPathExtension, withExtension: assetKey.pathExtension)?
      .deletingLastPathComponent()
    return DocumentWebView(frame: frame, file: file, assets: assets, document: document, channel: channel)
  }
}

private final class ViewerResources: NSObject, WKURLSchemeHandler {
  private let file: URL?
  private let assets: URL?
  private let queue = DispatchQueue(label: "kkomi.viewer.resources", qos: .userInitiated)
  private var requests: [ObjectIdentifier: UUID] = [:]

  init(file: URL?, assets: URL?) {
    self.file = file
    self.assets = assets?.resolvingSymlinksInPath()
  }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url, url.scheme == viewerURL.scheme, url.host == viewerURL.host,
      url.port == nil, url.user == nil, url.password == nil, url.query == nil,
      task.request.httpMethod == "GET"
    else {
      task.didFailWithError(URLError(.unsupportedURL))
      return
    }
    let id = ObjectIdentifier(task as AnyObject)
    let request = UUID()
    requests[id] = request
    queue.async { [self] in
      let resource = Result { try read(url) }
      DispatchQueue.main.async { [self] in
        guard requests[id] == request else { return }
        requests[id] = nil
        switch resource {
        case .success(let (data, mime)):
          var headers = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
          ]
          if ["office-worker.js", "pdf.worker.min.mjs"].contains(url.lastPathComponent) {
            headers["Content-Security-Policy"] = workerContentPolicy
          }
          let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
          task.didReceive(response)
          task.didReceive(data)
          task.didFinish()
        case .failure(let error):
          task.didFailWithError(error)
        }
      }
    }
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
    requests[ObjectIdentifier(task as AnyObject)] = nil
  }

  private func read(_ url: URL) throws -> (Data, String) {
    if url.path == "/document", let file {
      let properties = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard properties.isRegularFile == true, let size = properties.fileSize, size <= maxDocumentBytes else {
        throw URLError(.dataLengthExceedsMaximum)
      }
      let data = try Data(contentsOf: file, options: .mappedIfSafe)
      guard data.count <= maxDocumentBytes else { throw URLError(.dataLengthExceedsMaximum) }
      if ["heic", "heif", "tif", "tiff"].contains(file.pathExtension.lowercased()) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
          ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        let preview = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
          preview, UTType.png.identifier as CFString, 1, nil
        ) else { throw URLError(.cannotDecodeContentData) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), preview.length <= maxDocumentBytes
        else { throw URLError(.cannotDecodeContentData) }
        return (preview as Data, "image/png")
      }
      return (data, "application/octet-stream")
    }
    guard url.path.hasPrefix("/assets/"), let assets else { throw URLError(.fileDoesNotExist) }
    let path = String(url.path.dropFirst("/assets/".count))
    guard !path.isEmpty, !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
      throw URLError(.unsupportedURL)
    }
    let resource = assets.appendingPathComponent(path).resolvingSymlinksInPath()
    guard resource.path.hasPrefix(assets.path + "/") else { throw URLError(.unsupportedURL) }
    let mime: String
    switch resource.pathExtension {
    case "html": mime = "text/html; charset=utf-8"
    case "js", "mjs": mime = "text/javascript; charset=utf-8"
    case "css": mime = "text/css; charset=utf-8"
    case "wasm": mime = "application/wasm"
    default: mime = "application/octet-stream"
    }
    return (try Data(contentsOf: resource, options: .mappedIfSafe), mime)
  }
}

private final class ViewerMessageHandler: NSObject, WKScriptMessageHandler {
  weak var viewer: DocumentWebView?

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, message.frameInfo.request.url == viewerURL,
      let text = message.body as? String, let data = text.data(using: .utf8),
      let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let event = body["event"] as? String
    else { return }
    viewer?.receive(event, body["value"])
  }
}

private final class DocumentWebView: NSObject, FlutterPlatformView, WKNavigationDelegate, UIDocumentPickerDelegate {
  private let webView: WKWebView
  private let channel: FlutterMethodChannel
  private let fileExtension: String
  private let viewerStrings: String
  private let name: String
  private let hasFile: Bool
  private var pageCount = 0
  private var startupTimeout: DispatchWorkItem?
  private var canPrintHwp = false
  private var slidePaper: CGSize?
  private var printResult: FlutterResult?
  private var printTimeout: DispatchWorkItem?
  private var exportDirectory: URL?

  private var isHwp: Bool { fileExtension == "hwp" || fileExtension == "hwpx" }
  private var isSlide: Bool { fileExtension == "ppt" || fileExtension == "pptx" }

  init(frame: CGRect, file: URL?, assets: URL?, document: [String: String], channel: FlutterMethodChannel) {
    self.channel = channel
    self.fileExtension = document["extension"] ?? ""
    self.viewerStrings = document["viewerStrings"] ?? "{}"
    self.name = document["name"] ?? "문서"
    self.hasFile = file != nil
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(ViewerResources(file: file, assets: assets), forURLScheme: viewerURL.scheme!)
    let handler = ViewerMessageHandler()
    configuration.userContentController.add(handler, name: "Kkomi")
    configuration.userContentController.addUserScript(WKUserScript(
      source: "globalThis.Kkomi = window.webkit.messageHandlers.Kkomi;",
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true
    ))
    webView = WKWebView(frame: frame, configuration: configuration)
    super.init()
    handler.viewer = self
    webView.navigationDelegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      self.handle(call, result: result)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    startupTimeout?.cancel()
    printTimeout?.cancel()
    if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
  }

  func view() -> UIView { webView }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      if hasFile {
        startupTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.failStartup() }
        startupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        webView.load(URLRequest(url: viewerURL))
      } else {
        channel.invokeMethod("error", arguments: "파일을 읽을 수 없습니다. 다시 선택해 주세요.")
      }
    case "find":
      let arguments = call.arguments as? [String: Any]
      let query = json(arguments?["query"] as? String ?? "")
      let request = arguments?["request"] as? Int ?? 0
      webView.evaluateJavaScript("void window.findInDocument(\(query), \(request))")
    case "match":
      webView.evaluateJavaScript("void window.moveToMatch(\(call.arguments as? Int ?? 1))")
    case "page":
      webView.evaluateJavaScript("void window.goToPage(\(call.arguments as? Int ?? 0))")
    case "imageFit":
      let fit = call.arguments as? Bool ?? true
      webView.evaluateJavaScript("void window.setImageFit(\(fit))")
    case "password":
      let password = (call.arguments as? String).map(json) ?? "null"
      webView.evaluateJavaScript("void window.submitPassword(\(password))")
    case "print":
      beginPrint(result)
      return
    default:
      result(FlutterMethodNotImplemented)
      return
    }
    result(nil)
  }

  private func json(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    let allowed = action.targetFrame?.isMainFrame == true && action.request.url == viewerURL
    decisionHandler(allowed ? .allow : .cancel)
  }

  private func failStartup() {
    guard let startupTimeout else { return }
    startupTimeout.cancel()
    self.startupTimeout = nil
    channel.invokeMethod("error", arguments: "문서 뷰어를 시작할 수 없습니다.")
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failStartup()
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    failStartup()
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    startupTimeout?.cancel()
    startupTimeout = nil
    completePrint(error: "PDF를 준비할 수 없습니다.")
    channel.invokeMethod("error", arguments: "문서 뷰어가 종료됐습니다. 파일을 다시 열어 주세요.")
  }

  fileprivate func receive(_ event: String, _ value: Any?) {
    switch event {
    case "viewerReady":
      guard let startupTimeout else { return }
      startupTimeout.cancel()
      self.startupTimeout = nil
      webView.evaluateJavaScript("void window.openDocument(\(json(fileExtension)), \(json(viewerStrings)))") { [weak self] _, error in
        if error != nil {
          self?.channel.invokeMethod("error", arguments: "문서 뷰어를 시작할 수 없습니다.")
        }
      }
    case "ready":
      pageCount = value as? Int ?? 0
      channel.invokeMethod(event, arguments: pageCount)
    case "canPrint":
      canPrintHwp = value as? Bool ?? false
      channel.invokeMethod(event, arguments: canPrintHwp)
    case "outline":
      if isHwp, let outline = value as? String {
        channel.invokeMethod(event, arguments: outline)
      }
    case "page", "error", "password", "matches":
      channel.invokeMethod(event, arguments: value)
    case "printMedia":
      if isSlide, let size = dimensions(value),
        (1000...40000).contains(size.width), (1000...40000).contains(size.height) {
        slidePaper = CGSize(width: size.width * 0.072, height: size.height * 0.072)
      }
    case "printReady":
      guard isHwp, printResult != nil, exportDirectory == nil else { return }
      guard let size = dimensions(value) else { completePrint(error: "PDF를 준비할 수 없습니다."); return }
      exportPdf(paper: size.width > size.height ? CGSize(width: 842, height: 595) : CGSize(width: 595, height: 842))
    case "printError":
      completePrint(error: value as? String ?? "PDF를 준비할 수 없습니다.")
    default:
      break
    }
  }

  private func dimensions(_ value: Any?) -> CGSize? {
    guard let values = value as? [String: NSNumber], let width = values["width"]?.doubleValue,
      let height = values["height"]?.doubleValue, width.isFinite, height.isFinite, width > 0, height > 0
    else { return nil }
    return CGSize(width: width, height: height)
  }

  private func beginPrint(_ result: @escaping FlutterResult) {
    let printable = isHwp ? canPrintHwp : ["txt", "csv", "doc", "docx", "ppt", "pptx", "xls", "xlsx"].contains(fileExtension)
    guard pageCount > 0, printable else {
      result(FlutterError(code: "print", message: "이 문서는 PDF로 저장할 수 없습니다.", details: nil))
      return
    }
    guard printResult == nil else {
      result(FlutterError(code: "print", message: "이미 PDF를 준비하고 있습니다.", details: nil))
      return
    }
    printResult = result
    let timeout = DispatchWorkItem { [weak self] in self?.completePrint(error: "PDF를 준비하는 데 시간이 너무 걸립니다.") }
    printTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: timeout)
    if isHwp {
      webView.evaluateJavaScript("void window.prepareHwpPrint()") { [weak self] _, error in
        if error != nil { self?.completePrint(error: "PDF를 준비할 수 없습니다.") }
      }
    } else if isSlide {
      let size = slidePaper ?? CGSize(width: 842, height: 595)
      webView.evaluateJavaScript("window.fitOfficeSlides?.(\(size.width / 0.75), \(size.height / 0.75))") { [weak self] _, error in
        if error == nil { self?.exportPdf(paper: size) }
        else { self?.completePrint(error: "PDF를 준비할 수 없습니다.") }
      }
    } else {
      exportPdf(paper: CGSize(width: 595, height: 842))
    }
  }

  private func exportPdf(paper: CGSize) {
    guard printResult != nil, exportDirectory == nil else { return }
    printTimeout?.cancel()
    printTimeout = nil
    guard var presenter = webView.window?.rootViewController else {
      completePrint(error: "PDF를 저장할 수 없습니다.")
      return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    exportDirectory = directory
    let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    let labels = (try? JSONSerialization.jsonObject(with: Data(viewerStrings.utf8))) as? [String: String]
    let filename = stem.isEmpty ? "\(labels?["document"] ?? "문서").pdf" : "\(stem.prefix(100)).pdf"
    let output = directory.appendingPathComponent(filename)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let renderer = ViewerPrintRenderer(paper: paper)
      renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
      let count = renderer.numberOfPages
      guard (1...2000).contains(count), !isHwp || count == pageCount else { throw URLError(.cannotDecodeContentData) }
      renderer.prepare(forDrawingPages: NSRange(location: 0, length: count))
      try UIGraphicsPDFRenderer(bounds: renderer.paperRect).writePDF(to: output) { context in
        for page in 0..<count {
          context.beginPage()
          renderer.drawPage(at: page, in: renderer.paperRect)
        }
      }
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(forExporting: [output], asCopy: true)
      } else {
        picker = UIDocumentPickerViewController(url: output, in: .exportToService)
      }
      picker.delegate = self
      presenter.present(picker, animated: true)
    } catch {
      completePrint(error: "PDF를 저장할 수 없습니다.")
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    completePrint()
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    completePrint()
  }

  private func completePrint(error: String? = nil) {
    guard let result = printResult else { return }
    printResult = nil
    printTimeout?.cancel()
    printTimeout = nil
    if isHwp { webView.evaluateJavaScript("void window.releaseHwpPrint()") }
    if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
    exportDirectory = nil
    result(error.map { FlutterError(code: "print", message: $0, details: nil) })
  }
}

private final class ViewerPrintRenderer: UIPrintPageRenderer {
  private let bounds: CGRect

  init(paper: CGSize) {
    bounds = CGRect(origin: .zero, size: paper)
    super.init()
  }

  override var paperRect: CGRect { bounds }
  override var printableRect: CGRect { bounds }
}
