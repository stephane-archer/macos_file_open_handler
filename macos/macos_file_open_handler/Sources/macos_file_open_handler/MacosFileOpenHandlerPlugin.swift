import Cocoa
import FlutterMacOS

public final class MacosFileOpenHandlerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
  FlutterAppLifecycleDelegate
{
  private struct OpenBatch {
    struct OpenedURL {
      let url: URL
      let didStartAccessing: Bool
    }

    let id: String
    let openedURLs: [OpenedURL]

    var payload: [String: Any] {
      [
        "batchId": id,
        "files": openedURLs.map { openedURL in
          let url = openedURL.url
          return [
            "name": url.lastPathComponent,
            "path": url.path,
            "uri": url.absoluteString,
          ]
        },
      ]
    }
  }

  private let idGenerator: () -> String
  private let startAccessing: (URL) -> Bool
  private let stopAccessing: (URL) -> Void
  private var eventSink: FlutterEventSink?
  private var retainedBatches: [String: OpenBatch] = [:]
  private var pendingBatchIDs: [String] = []

  public override convenience init() {
    self.init(
      idGenerator: { UUID().uuidString },
      startAccessing: { $0.startAccessingSecurityScopedResource() },
      stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
  }

  /// Creates a plugin with injectable lifecycle operations for native tests.
  init(
    idGenerator: @escaping () -> String,
    startAccessing: @escaping (URL) -> Bool,
    stopAccessing: @escaping (URL) -> Void
  ) {
    self.idGenerator = idGenerator
    self.startAccessing = startAccessing
    self.stopAccessing = stopAccessing
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "macos_file_open_handler",
      binaryMessenger: registrar.messenger
    )
    let eventChannel = FlutterEventChannel(
      name: "macos_file_open_handler/events",
      binaryMessenger: registrar.messenger
    )
    let instance = MacosFileOpenHandlerPlugin()
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
    registrar.addApplicationDelegate(instance)
  }

  deinit {
    releaseAllBatches()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "releaseBatch":
      guard
        let arguments = call.arguments as? [String: Any],
        let batchID = arguments["batchId"] as? String,
        !batchID.isEmpty
      else {
        result(FlutterError(
          code: "InvalidArguments",
          message: "releaseBatch expects a non-empty batchId string.",
          details: nil
        ))
        return
      }
      releaseBatch(batchID)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    let pending = pendingBatchIDs
    pendingBatchIDs.removeAll()
    for batchID in pending {
      if let batch = retainedBatches[batchID] {
        events(batch.payload)
      }
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    releaseAllBatches()
    return nil
  }

  public func handleOpen(_ urls: [URL]) -> Bool {
    let fileURLs = urls.filter(\.isFileURL)
    guard !fileURLs.isEmpty else {
      return false
    }

    let batch = OpenBatch(
      id: idGenerator(),
      openedURLs: fileURLs.map { url in
        OpenBatch.OpenedURL(url: url, didStartAccessing: startAccessing(url))
      }
    )
    retainedBatches[batch.id] = batch
    if let eventSink {
      eventSink(batch.payload)
    } else {
      pendingBatchIDs.append(batch.id)
    }
    // Flutter stops dispatching this callback after a delegate returns true.
    // A mixed batch must continue to later delegates so URL-scheme plugins can
    // handle its non-file URLs. Those delegates are expected to filter URLs in
    // the same way this plugin does.
    return fileURLs.count == urls.count
  }

  public func handleWillTerminate(_ notification: Notification) {
    releaseAllBatches()
  }

  private func releaseBatch(_ batchID: String) {
    pendingBatchIDs.removeAll { $0 == batchID }
    guard let batch = retainedBatches.removeValue(forKey: batchID) else {
      return
    }
    for openedURL in batch.openedURLs where openedURL.didStartAccessing {
      stopAccessing(openedURL.url)
    }
  }

  private func releaseAllBatches() {
    let batches = retainedBatches.values
    retainedBatches.removeAll()
    pendingBatchIDs.removeAll()
    for batch in batches {
      for openedURL in batch.openedURLs where openedURL.didStartAccessing {
        stopAccessing(openedURL.url)
      }
    }
  }
}
