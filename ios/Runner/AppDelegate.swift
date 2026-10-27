import Flutter
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Plays on-device songs with the Personalize sound effects (FxPlayer.swift).
  private var fxPlayer: FxPlayer?
  /// Tells the app if the phone is on Wi-Fi or mobile data (Download over Wi-Fi only).
  private var networkBridge: NetworkBridge?
  /// Hands a finished backup .zip to the Files "Save to..." screen.
  private var backupExport: BackupExport?

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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BackupExport") {
      backupExport = BackupExport(messenger: registrar.messenger())
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

/// Answers "exportFile" on the channel "ytmusicweb/backup": shows the system
/// "Save to Files" screen for a finished backup file and replies true (saved)
/// or false (cancelled). The file is copied, so the app can delete its own copy.
final class BackupExport: NSObject, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private var pending: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ytmusicweb/backup", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "exportFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "args", message: "No file given", details: nil))
        return
      }
      self?.export(path: path, result: result)
    }
  }

  private func topController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
      ?? scene?.windows.first?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
  }

  private func export(path: String, result: @escaping FlutterResult) {
    if pending != nil {
      result(FlutterError(code: "busy", message: "Another save is already open", details: nil))
      return
    }
    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "missing", message: "The backup file is missing", details: nil))
      return
    }
    guard let top = topController() else {
      result(FlutterError(code: "save", message: "Could not open the save screen", details: nil))
      return
    }
    let url = URL(fileURLWithPath: path)
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    } else {
      picker = UIDocumentPickerViewController(url: url, in: .exportToService)
    }
    picker.delegate = self
    pending = result
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let r = pending
    pending = nil
    r?(true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
    let r = pending
    pending = nil
    r?(true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let r = pending
    pending = nil
    r?(false)
  }
}
