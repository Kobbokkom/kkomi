import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var documents: DocumentAccess?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let registrar = registrar(forPlugin: "KkomiDocuments") {
      documents = DocumentAccess(messenger: registrar.messenger()) { [weak self] in
        var presenter = self?.window?.rootViewController
        while let presented = presenter?.presentedViewController {
          presenter = presented
        }
        return presenter
      }
      registrar.register(DocumentWebViewFactory(registrar: registrar), withId: "kkomi/viewer")
    }
    return launched
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if documents?.open(url) == true { return true }
    return super.application(app, open: url, options: options)
  }
}
