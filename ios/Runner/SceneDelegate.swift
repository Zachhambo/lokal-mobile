import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    (UIApplication.shared.delegate as? AppDelegate)?.openWidgetURLs(connectionOptions.urlContexts.map { $0.url })
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    (UIApplication.shared.delegate as? AppDelegate)?.openDocuments(connectionOptions.urlContexts.map { $0.url })
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    (UIApplication.shared.delegate as? AppDelegate)?.openWidgetURLs(URLContexts.map { $0.url })
    super.scene(scene, openURLContexts: URLContexts)
    (UIApplication.shared.delegate as? AppDelegate)?.openDocuments(URLContexts.map { $0.url })
  }
}
