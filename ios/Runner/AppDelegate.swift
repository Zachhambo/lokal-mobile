import Flutter
import UIKit
import UserNotifications

@_silgen_name("lokal_soulseek_suspend") private func suspendSoulseek()
@_silgen_name("lokal_soulseek_resume") private func resumeSoulseek()

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var widgetBridge: LokalWidgetBridge?
  private var lokalPlatform: LokalPlatform?
  private let transferHost = LokalTransferHost()
  private var transferBridge: LokalTransferBridge?
  #if DEBUG
  private var transferIntegrationHarness: LokalTransferIntegrationHarness?
  private var daemonProbe: LokalTransferDaemonProbe?
  #endif
  private var lifecycleObservers: [NSObjectProtocol] = []
  private var protectedDataObserver: NSObjectProtocol?
  private var pendingDocuments: [URL] = []

  func openWidgetURLs(_ urls: [URL]) {
    for url in urls where url.scheme == "konnekted" && url.host == "widget" {
      if let widgetBridge { widgetBridge.open(url) }
      else if url.absoluteString.utf8.count <= 2048 {
        let key = "lokal.widget.pending-actions.v1"
        var pending = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !pending.contains(url.absoluteString) { pending.append(url.absoluteString) }
        UserDefaults.standard.set(Array(pending.suffix(8)), forKey: key)
      }
    }
  }

  override func application(_ app: UIApplication, open url: URL,
                            options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    if url.scheme == "konnekted", url.host == "widget" {
      openWidgetURLs([url])
      return true
    }
    return super.application(app, open: url, options: options)
  }

  func openDocuments(_ urls: [URL]) {
    if let platform = lokalPlatform { platform.openDocuments(urls) }
    else { pendingDocuments.append(contentsOf: urls.filter { $0.isFileURL }) }
  }
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["lokal.downloads"])
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["lokal.downloads"])
    transferHost.start()
    #if DEBUG
    do { daemonProbe = try LokalTransferDaemonProbe(); daemonProbe?.start() }
    catch { NSLog("Isolated daemon probe configuration refused") }
    #endif
    lifecycleObservers = [
      NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
        object: nil, queue: .main) { [weak self] _ in
          suspendSoulseek()
          #if DEBUG
          DispatchQueue.main.async { self?.daemonProbe?.backgrounded() }
          #endif
        },
      NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
        object: nil, queue: .main) { _ in resumeSoulseek() },
    ]
    protectedDataObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification,
      object: nil, queue: .main) { [host = transferHost] _ in host.start() }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    #if DEBUG
    if let probe = daemonProbe, probe.identifier == identifier {
      probe.handleBackgroundEvents(completionHandler)
      return
    }
    #endif
    guard identifier == LokalTransferRuntime.sessionIdentifier else {
      super.application(application, handleEventsForBackgroundURLSession: identifier,
        completionHandler: completionHandler)
      return
    }
    // This path works before Flutter initializes; importing into the library
    // is separate from retaining files and acknowledging native OS delivery.
    transferHost.handleBackgroundEvents(completion: completionHandler)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    widgetBridge = LokalWidgetBridge(messenger: engineBridge.applicationRegistrar.messenger())
    lokalPlatform = LokalPlatform(messenger: engineBridge.applicationRegistrar.messenger())
    transferBridge = LokalTransferBridge(
      messenger: engineBridge.applicationRegistrar.messenger(), host: transferHost)
    #if DEBUG
    transferIntegrationHarness = LokalTransferIntegrationHarness(
      messenger: engineBridge.applicationRegistrar.messenger())
    #endif
    registerDownloadNotifications(engineBridge.applicationRegistrar.messenger())
    lokalPlatform?.openDocuments(pendingDocuments)
    pendingDocuments = []
  }
  private func registerDownloadNotifications(_ messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "lokal/library_sync_notification", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        guard call.method == "update",
              let args = call.arguments as? [String: Any],
              args["kind"] as? String == "download" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let center = UNUserNotificationCenter.current()
        let publish: () -> Void = {
          let content = UNMutableNotificationContent()
          content.title = args["title"] as? String ?? "Downloads"
          content.body = args["message"] as? String ?? ""
          content.threadIdentifier = "lokal.downloads"
          // Replace the progress notice silently instead of stacking alerts.
          content.sound = nil
          let request = UNNotificationRequest(identifier: "lokal.downloads",
            content: content, trigger: nil)
          center.add(request) { error in
            DispatchQueue.main.async { result(error == nil) }
          }
        }
        center.getNotificationSettings { settings in
          if settings.authorizationStatus == .notDetermined,
             args["begin"] as? Bool == true {
            center.requestAuthorization(options: [.alert]) { granted, _ in
              if granted { publish() }
              else { DispatchQueue.main.async { result(false) } }
            }
          } else if settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional {
            publish()
          } else {
            DispatchQueue.main.async { result(false) }
          }
        }
      }
  }
}
