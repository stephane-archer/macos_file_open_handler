import Cocoa
import FlutterMacOS
import XCTest
@testable import macos_file_open_handler

final class RunnerTests: XCTestCase {
  func testColdStartQueuesUntilFlutterListens() throws {
    let harness = PluginHarness(ids: ["cold"])
    let file = URL(fileURLWithPath: "/tmp/My Video.mov")

    XCTAssertTrue(harness.plugin.handleOpen([file]))
    XCTAssertTrue(harness.events.isEmpty)

    harness.listen()

    let payload = try XCTUnwrap(harness.events.single as? [String: Any])
    XCTAssertEqual(payload["batchId"] as? String, "cold")
    let files = try XCTUnwrap(payload["files"] as? [[String: String]])
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(files[0]["name"], "My Video.mov")
    XCTAssertEqual(files[0]["path"], file.path)
    XCTAssertEqual(files[0]["uri"], file.absoluteString)
    XCTAssertTrue(harness.stoppedURLs.isEmpty)
  }

  func testWarmEventsHaveUniqueBatchIDsAndPreserveOrder() throws {
    let harness = PluginHarness(ids: ["first", "second"])
    harness.listen()

    XCTAssertTrue(harness.plugin.handleOpen([URL(fileURLWithPath: "/tmp/first.mov")]))
    XCTAssertTrue(harness.plugin.handleOpen([URL(fileURLWithPath: "/tmp/second.mov")]))

    let payloads = try harness.events.map { event in
      try XCTUnwrap(event as? [String: Any])
    }
    XCTAssertEqual(payloads.map { $0["batchId"] as? String }, ["first", "second"])
  }

  func testReleaseIsIdempotentAndReleasesEveryFileOccurrence() {
    let harness = PluginHarness(ids: ["duplicates"])
    let file = URL(fileURLWithPath: "/tmp/repeated.mov")
    XCTAssertTrue(harness.plugin.handleOpen([file, file]))

    XCTAssertNil(harness.invoke("releaseBatch", arguments: ["batchId": "duplicates"]))
    XCTAssertEqual(harness.stoppedURLs, [file, file])

    XCTAssertNil(harness.invoke("releaseBatch", arguments: ["batchId": "duplicates"]))
    XCTAssertEqual(harness.stoppedURLs, [file, file])
  }

  func testStopsOnlyScopesThatWereSuccessfullyStarted() {
    let harness = PluginHarness(ids: ["partial"], startResults: [true, false])
    let first = URL(fileURLWithPath: "/tmp/first.mov")
    let second = URL(fileURLWithPath: "/tmp/second.mov")

    XCTAssertTrue(harness.plugin.handleOpen([first, second]))
    XCTAssertEqual(harness.startedURLs, [first, second])

    XCTAssertNil(harness.invoke("releaseBatch", arguments: ["batchId": "partial"]))
    XCTAssertEqual(harness.stoppedURLs, [first])
  }

  func testRejectsNonFileURLsWithoutClaimingThem() {
    let harness = PluginHarness(ids: ["unused"])
    harness.listen()

    XCTAssertFalse(harness.plugin.handleOpen([URL(string: "my-app://open/item")!]))
    XCTAssertTrue(harness.events.isEmpty)
    XCTAssertTrue(harness.stoppedURLs.isEmpty)
  }

  func testMixedEventsContainOnlyFileURLsAndContinueToOtherDelegates() throws {
    let harness = PluginHarness(ids: ["mixed"])
    harness.listen()
    let file = URL(fileURLWithPath: "/tmp/file.mov")

    XCTAssertFalse(
      harness.plugin.handleOpen([URL(string: "my-app://handled-elsewhere")!, file])
    )

    let payload = try XCTUnwrap(harness.events.single as? [String: Any])
    let files = try XCTUnwrap(payload["files"] as? [[String: String]])
    XCTAssertEqual(files.map { $0["path"] }, [file.path])
  }

  func testCancellationReleasesAllOutstandingBatches() {
    let harness = PluginHarness(ids: ["one", "two"])
    harness.listen()
    let first = URL(fileURLWithPath: "/tmp/one.mov")
    let second = URL(fileURLWithPath: "/tmp/two.mov")
    XCTAssertTrue(harness.plugin.handleOpen([first]))
    XCTAssertTrue(harness.plugin.handleOpen([second]))

    XCTAssertNil(harness.plugin.onCancel(withArguments: nil))

    XCTAssertEqual(Set(harness.stoppedURLs), Set([first, second]))
    XCTAssertNil(harness.invoke("releaseBatch", arguments: ["batchId": "one"]))
    XCTAssertEqual(harness.stoppedURLs.count, 2)
  }

  func testTerminationReleasesColdStartBatches() {
    let harness = PluginHarness(ids: ["pending"])
    let file = URL(fileURLWithPath: "/tmp/pending.mov")
    XCTAssertTrue(harness.plugin.handleOpen([file]))

    harness.plugin.handleWillTerminate(
      Notification(name: NSApplication.willTerminateNotification)
    )

    XCTAssertEqual(harness.stoppedURLs, [file])
    harness.listen()
    XCTAssertTrue(harness.events.isEmpty)
  }

  func testInvalidReleaseArgumentsAndUnknownMethods() {
    let harness = PluginHarness(ids: [])

    let invalid = harness.invoke("releaseBatch", arguments: nil) as? FlutterError
    XCTAssertEqual(invalid?.code, "InvalidArguments")
    XCTAssertTrue(
      (harness.invoke("unknown", arguments: nil) as? NSObject) === FlutterMethodNotImplemented
    )
  }
}

private final class PluginHarness {
  let plugin: MacosFileOpenHandlerPlugin
  var events: [Any?] = []
  private let accessRecorder: AccessRecorder

  var startedURLs: [URL] {
    accessRecorder.startedURLs
  }

  var stoppedURLs: [URL] {
    accessRecorder.stoppedURLs
  }

  init(ids: [String], startResults: [Bool] = []) {
    var remainingIDs = ids
    var remainingStartResults = startResults
    let accessRecorder = AccessRecorder()
    self.accessRecorder = accessRecorder
    plugin = MacosFileOpenHandlerPlugin(
      idGenerator: { remainingIDs.removeFirst() },
      startAccessing: { url in
        accessRecorder.startedURLs.append(url)
        return remainingStartResults.isEmpty ? true : remainingStartResults.removeFirst()
      },
      stopAccessing: { accessRecorder.stoppedURLs.append($0) }
    )
  }

  func listen() {
    _ = plugin.onListen(withArguments: nil) { [weak self] event in
      self?.events.append(event)
    }
  }

  func invoke(_ method: String, arguments: Any?) -> Any? {
    var value: Any?
    plugin.handle(FlutterMethodCall(methodName: method, arguments: arguments)) {
      value = $0
    }
    return value
  }
}

private final class AccessRecorder {
  var startedURLs: [URL] = []
  var stoppedURLs: [URL] = []
}

private extension Array {
  var single: Element? {
    count == 1 ? first : nil
  }
}
