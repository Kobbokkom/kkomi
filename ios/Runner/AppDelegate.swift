import AppTrackingTransparency
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var documents: DocumentAccess?

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)
    guard let registrar = registry.registrar(forPlugin: "KkomiDocuments") else { return }
    let documents = DocumentAccess(messenger: registrar.messenger()) { [weak registrar] in
      var presenter = registrar?.viewController
      while let presented = presenter?.presentedViewController {
        presenter = presented
      }
      return presenter
    }
    self.documents = documents
    registrar.addSceneDelegate(documents)
    registrar.register(DocumentWebViewFactory(registrar: registrar), withId: "kkomi/viewer")
    FlutterMethodChannel(name: "kkomi/tracking", binaryMessenger: registrar.messenger())
      .setMethodCallHandler { _, result in Self.requestTracking(result) }
  }

  // The system skips the prompt unless the app is active, so wait for activation.
  private static func requestTracking(_ result: @escaping FlutterResult) {
    guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else {
      result(nil)
      return
    }
    guard UIApplication.shared.applicationState == .active else {
      var token: NSObjectProtocol?
      token = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { _ in
        if let token { NotificationCenter.default.removeObserver(token) }
        requestTracking(result)
      }
      return
    }
    ATTrackingManager.requestTrackingAuthorization { _ in
      DispatchQueue.main.async { result(nil) }
    }
  }
}
