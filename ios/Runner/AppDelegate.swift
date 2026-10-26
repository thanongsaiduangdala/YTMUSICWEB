import Flutter
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Plays on-device songs with the Personalize sound effects (FxPlayer.swift).
  private var fxPlayer: FxPlayer?
  /// Tells the app if the phone is on Wi-Fi or mobile data (Download over Wi-Fi only).
  private var networkBridge: NetworkBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FxPlayer") {
      fxPlayer = FxPlayer(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NetworkBridge") {
      networkBridge = NetworkBridge(messenger: registrar.messenger())
    }
  }
}

/// Answers "network" on the channel "ytmusicweb/ytdlp" (the Android side of the
/// same channel runs yt-dlp; here only the network check exists).
/// Replies "wifi" (Wi-Fi or ethernet), "mobile", "none" or "other".
final class NetworkBridge {
  private let channel: FlutterMethodChannel
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "ytmusicweb.network")
  private var path: NWPath?  // only touched on `queue`

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ytmusicweb/ytdlp", binaryMessenger: messenger)
    monitor.pathUpdateHandler = { [weak self] p in self?.path = p }
    monitor.start(queue: queue)
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "network" {
        result(self?.networkType() ?? "other")
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func networkType() -> String {
    let p: NWPath? = queue.sync { path }
    // No answer from the system yet: do not block downloads by mistake.
    guard let p = p else { return "other" }
    if p.status != .satisfied { return "none" }
    if p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet) { return "wifi" }
    if p.usesInterfaceType(.cellular) { return "mobile" }
    return "other"
  }
}
