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
  }
}
