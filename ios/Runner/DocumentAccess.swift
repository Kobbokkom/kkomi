import Darwin
import Flutter
import PhotosUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

final class DocumentAccess: NSObject, UIDocumentPickerDelegate, PHPickerViewControllerDelegate,
  QLPreviewControllerDataSource, QLPreviewControllerDelegate {
  private static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "gif", "webp", "bmp", "avif", "heic", "heif", "tif", "tiff",
  ]
  private static let extensions = imageExtensions.union([
    "hwp", "hwpx", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv",
  ])
  private static let maxBytes = 64 * 1024 * 1024
  private static let importScheme = "kkomi-import"
  private static let importDirectory = FileManager.default.urls(
    for: .documentDirectory, in: .userDomainMask
  )[0].appendingPathComponent("Imports", isDirectory: true)
  private static let legacyCacheDirectory = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask
  )[0].appendingPathComponent("file_cache", isDirectory: true)

  private let channel: FlutterMethodChannel
  private let presenter: () -> UIViewController?
  private let imports = DispatchQueue(label: "kkomi.imports", qos: .userInitiated)
  private var pickerResult: FlutterResult?
  private var previewItem: NSURL?
  private var previewResult: FlutterResult?
  private var ready = false
  private var pending: [(String, Any)] = []

  init(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) {
    channel = FlutterMethodChannel(name: "kkomi/documents", binaryMessenger: messenger)
    self.presenter = presenter
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
  }

  @discardableResult
  func open(_ url: URL) -> Bool {
    guard url.isFileURL, Self.extensions.contains(url.pathExtension.lowercased()) else {
      return false
    }
    importDocument(url) { [weak self] outcome in
      guard let self else { return }
      let event: (String, Any)
      switch outcome {
      case .success(let document): event = ("open", document)
      case .failure(let error): event = ("openError", error.message)
      }
      if self.ready {
        self.channel.invokeMethod(event.0, arguments: event.1)
      } else {
        self.pending.append(event)
      }
    }
    return true
  }

  static func importedFile(_ uri: String) throws -> URL {
    let file = try importLocation(uri)
    try validateFile(file)
    return file
  }

  private static func validateFile(_ file: URL) throws {
    let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard properties.isRegularFile == true else { throw DocumentError.invalidFile }
    guard let size = properties.fileSize, size <= maxBytes else { throw DocumentError.tooLarge }
  }

  private static func importLocation(_ uri: String) throws -> URL {
    guard let url = URL(string: uri),
      url.user == nil, url.password == nil, url.port == nil,
      url.query == nil, url.fragment == nil,
      extensions.contains(url.pathExtension.lowercased())
    else { throw DocumentError.invalidFile }

    let folder: String?
    if url.scheme == importScheme && url.pathComponents.count == 2 {
      folder = url.host
    } else if url.isFileURL && (url.host ?? "").isEmpty {
      let suffix = Array(url.pathComponents.suffix(5))
      // iOS may change the data-container UUID after an app update.
      folder = suffix.count == 5 && UUID(uuidString: suffix[0]) != nil &&
        suffix[1] == "Documents" && suffix[2] == "Imports" ? suffix[3] : nil
    } else {
      folder = nil
    }
    guard let folder, UUID(uuidString: folder) != nil else { throw DocumentError.invalidFile }
    let base = importDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let expectedParent = base.appendingPathComponent(folder, isDirectory: true)
    let location = expectedParent.appendingPathComponent(url.lastPathComponent)
      .standardizedFileURL.resolvingSymlinksInPath()
    guard location.deletingLastPathComponent().path == expectedParent.path
    else { throw DocumentError.invalidFile }
    return location
  }

  private static func importIdentifier(_ file: URL) -> String {
    var parts = URLComponents()
    parts.scheme = importScheme
    parts.host = file.deletingLastPathComponent().lastPathComponent
    parts.path = "/" + file.lastPathComponent
    return parts.string!
  }

  private static func restoreLegacyDocument(_ entry: [String: String]) throws -> [String: String] {
    guard let path = entry["path"], let name = entry["name"], let openedAt = entry["openedAt"],
      let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(string: path)
    else { throw DocumentError.invalidFile }
    var document: [String: String]
    if let imported = try? importedFile(url.absoluteString) {
      document = [
        "uri": importIdentifier(imported), "name": name,
        "extension": imported.pathExtension.lowercased(),
      ]
    } else {
      let suffix = Array(url.pathComponents.suffix(5))
      guard url.isFileURL, (url.host ?? "").isEmpty, url.query == nil, url.fragment == nil,
        suffix.count == 5, UUID(uuidString: suffix[0]) != nil,
        suffix[1...3].elementsEqual(["Library", "Application Support", "file_cache"])
      else { throw DocumentError.invalidFile }
      let base = legacyCacheDirectory.standardizedFileURL.resolvingSymlinksInPath()
      let source = base.appendingPathComponent(url.lastPathComponent)
        .standardizedFileURL.resolvingSymlinksInPath()
      guard source.deletingLastPathComponent().path == base.path else {
        throw DocumentError.invalidFile
      }
      document = try store(source, name: name)
    }
    document["openedAt"] = openedAt
    return document
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let document = call.arguments as? [String: String]
    switch call.method {
    case "ready":
      ready = true
      result(nil)
      for (method, value) in pending {
        channel.invokeMethod(method, arguments: value)
      }
      pending.removeAll()
    case "pick":
      pick(result)
    case "pickPhoto":
      pickPhoto(result)
    case "share":
      share(document?["uri"], result: result)
    case "findMissingRecentDocuments":
      let uris = call.arguments as? [String] ?? []
      imports.async {
        let missing = uris.prefix(10).filter { uri in
          guard let url = try? Self.importLocation(uri) else { return true }
          var info = stat()
          return lstat(url.path, &info) == -1 && (errno == ENOENT || errno == ENOTDIR)
        }
        DispatchQueue.main.async { result(Array(missing)) }
      }
    case "forget":
      if let uri = document?["uri"], let url = try? Self.importLocation(uri) {
        imports.async {
          try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
      }
      result(nil)
    case "restoreLegacyDocuments":
      let entries = call.arguments as? [[String: String]] ?? []
      imports.async {
        let restored = entries.prefix(10).compactMap { try? Self.restoreLegacyDocument($0) }
        DispatchQueue.main.async { result(restored) }
      }
    case "openExternal":
      preview(document?["uri"], result: result)
    case "officeConverterAvailable":
      result(false)
    case "convertLocalText", "cachedOfficePdf", "docxEstimateBytes":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pick(_ result: @escaping FlutterResult) {
    guard pickerResult == nil, let presenter = presenter() else {
      result(FlutterError(code: "picker", message: "파일 선택기를 열 수 없습니다.", details: nil))
      return
    }
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
    } else {
      picker = UIDocumentPickerViewController(documentTypes: ["public.data"], in: .open)
    }
    picker.delegate = self
    picker.allowsMultipleSelection = false
    pickerResult = result
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pickerResult
    pickerResult = nil
    result?(nil)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    guard let result = pickerResult else { return }
    pickerResult = nil
    guard let url = urls.first else {
      result(nil)
      return
    }
    importDocument(url) { outcome in
      switch outcome {
      case .success(let document): result(document)
      case .failure(let error): result(error.flutter)
      }
    }
  }

  private func pickPhoto(_ result: @escaping FlutterResult) {
    guard pickerResult == nil, let presenter = presenter() else {
      result(FlutterError(code: "picker", message: "사진 선택기를 열 수 없습니다.", details: nil))
      return
    }
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    pickerResult = result
    presenter.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    guard let result = pickerResult else { return }
    pickerResult = nil
    picker.dismiss(animated: true) {
      guard let provider = results.first?.itemProvider else {
        result(nil)
        return
      }
      let imageType = provider.registeredTypeIdentifiers.first { identifier in
        guard let type = UTType(identifier), type.conforms(to: .image),
          let suffix = type.preferredFilenameExtension else { return false }
        return Self.imageExtensions.contains(suffix.lowercased())
      } ?? UTType.image.identifier
      provider.loadFileRepresentation(forTypeIdentifier: imageType) { url, _ in
        let value: Any
        if let url {
          do {
            // The provider removes this URL after the callback returns.
            let suffix = url.pathExtension.isEmpty
              ? UTType(imageType)?.preferredFilenameExtension ?? "" : url.pathExtension
            guard Self.imageExtensions.contains(suffix.lowercased()) else {
              throw DocumentError.unsupported
            }
            let original = provider.suggestedName ?? url.lastPathComponent
            let originalExtension = (original as NSString).pathExtension.lowercased()
            let baseName = Self.imageExtensions.contains(originalExtension)
              ? (original as NSString).deletingPathExtension : original
            let filename = "\(baseName).\(suffix)"
            value = try Self.store(url, name: filename)
          } catch {
            value = (error as? DocumentError ?? .invalidFile).flutter
          }
        } else {
          value = DocumentError.invalidFile.flutter
        }
        DispatchQueue.main.async { result(value) }
      }
    }
  }

  private func preview(_ uri: String?, result: @escaping FlutterResult) {
    guard previewResult == nil, let uri, let url = try? Self.importedFile(uri),
      let presenter = presenter(), QLPreviewController.canPreview(url as NSURL) else {
      result(FlutterError(code: "viewer", message: "iOS 미리보기를 사용할 수 없습니다.", details: nil))
      return
    }
    previewItem = url as NSURL
    previewResult = result
    let controller = QLPreviewController()
    controller.dataSource = self
    controller.delegate = self
    presenter.present(controller, animated: true)
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    return previewItem == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
    return previewItem!
  }

  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    let result = previewResult
    previewResult = nil
    previewItem = nil
    result?(nil)
  }

  private func share(_ uri: String?, result: FlutterResult) {
    guard let uri, let url = try? Self.importedFile(uri), let presenter = presenter() else {
      result(FlutterError(code: "share", message: "문서를 공유할 수 없습니다.", details: nil))
      return
    }
    let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    share.popoverPresentationController?.sourceView = presenter.view
    share.popoverPresentationController?.sourceRect = CGRect(
      x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1
    )
    presenter.present(share, animated: true)
    result(nil)
  }

  private func importDocument(
    _ source: URL, completion: @escaping (Result<[String: String], DocumentError>) -> Void
  ) {
    let scoped = source.startAccessingSecurityScopedResource()
    imports.async {
      defer {
        if scoped { source.stopAccessingSecurityScopedResource() }
      }
      var coordinationError: NSError?
      var outcome: Result<[String: String], DocumentError> = .failure(.invalidFile)
      NSFileCoordinator().coordinate(
        readingItemAt: source, options: .withoutChanges, error: &coordinationError
      ) { readable in
        do {
          outcome = .success(try Self.store(readable, name: source.lastPathComponent))
        } catch {
          outcome = .failure(error as? DocumentError ?? .invalidFile)
        }
      }
      let result = outcome
      DispatchQueue.main.async { completion(result) }
    }
  }

  private static func store(_ source: URL, name: String) throws -> [String: String] {
    let filename = URL(fileURLWithPath: name).lastPathComponent
    let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
    guard extensions.contains(fileExtension) else { throw DocumentError.unsupported }
    let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard properties.isRegularFile == true else { throw DocumentError.invalidFile }
    if let size = properties.fileSize, size > maxBytes { throw DocumentError.tooLarge }
    if let file = try? importedFile(source.absoluteString),
      file.path == source.standardizedFileURL.resolvingSymlinksInPath().path {
      return ["uri": importIdentifier(file), "name": filename, "extension": fileExtension]
    }

    var folder = importDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let target = folder.appendingPathComponent(filename)
    let files = FileManager.default
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    do {
      var privateCopy = URLResourceValues()
      privateCopy.isExcludedFromBackup = true
      try folder.setResourceValues(privateCopy)
      guard let input = InputStream(url: source), let output = OutputStream(url: target, append: false)
      else {
        throw DocumentError.invalidFile
      }
      input.open()
      output.open()
      defer { input.close(); output.close() }
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      var bytes = 0
      while true {
        let count = input.read(&buffer, maxLength: buffer.count)
        if count == 0 { break }
        guard count > 0 else { throw DocumentError.invalidFile }
        bytes += count
        guard bytes <= maxBytes else { throw DocumentError.tooLarge }
        try buffer.withUnsafeBufferPointer { chunk in
          var offset = 0
          while offset < count {
            let written = output.write(chunk.baseAddress! + offset, maxLength: count - offset)
            guard written > 0 else { throw DocumentError.invalidFile }
            offset += written
          }
        }
      }
      return ["uri": importIdentifier(target), "name": filename, "extension": fileExtension]
    } catch {
      try? files.removeItem(at: folder)
      throw error
    }
  }

  private enum DocumentError: Error {
    case invalidFile, unsupported, tooLarge

    var message: String {
      switch self {
      case .invalidFile: return "파일을 읽을 수 없습니다."
      case .unsupported: return "지원하지 않는 파일 형식입니다."
      case .tooLarge: return "64MB 이하의 문서를 열 수 있습니다."
      }
    }

    var flutter: FlutterError {
      FlutterError(code: "document", message: message, details: nil)
    }
  }
}
