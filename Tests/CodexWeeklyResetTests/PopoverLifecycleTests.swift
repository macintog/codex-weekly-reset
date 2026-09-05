import AppKit
import XCTest
@testable import CodexWeeklyReset

final class PopoverLifecycleTests: XCTestCase {
  @MainActor
  func testHiddenWindowIsNotMovedOnAttachmentOrUpdate() async {
    _ = NSApplication.shared
    var moves = 0
    let view = WindowReportingView { _ in moves += 1 }
    let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 386, height: 371),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    view.requestAlignment()
    await drainMainQueue()
    XCTAssertFalse(window.isVisible)
    XCTAssertEqual(moves, 0, "Attaching content must not reposition an unpresented native window")
    window.contentView = nil
  }

  @MainActor
  func testPresentationAlignsOnceAndResizeCanAlignAgain() async {
    _ = NSApplication.shared
    var reported: [NSWindow] = []
    let view = WindowReportingView { reported.append($0) }
    let window = makeWindow()
    window.contentView = view
    await drainMainQueue()
    XCTAssertTrue(reported.isEmpty)

    window.visibleForTest = true
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    view.requestAlignment()
    view.requestAlignment()
    XCTAssertTrue(reported.isEmpty, "Do not move inside the native presentation callback")
    await drainMainQueue()
    XCTAssertEqual(reported.count, 1)
    XCTAssertTrue(reported.first === window)

    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
    await drainMainQueue()
    XCTAssertEqual(reported.count, 2)
    window.contentView = nil
  }

  @MainActor
  func testClosingBeforeQueuedAlignmentDoesNotMoveWindow() async {
    _ = NSApplication.shared
    var moves = 0
    let view = WindowReportingView { _ in moves += 1 }
    let window = makeWindow()
    window.contentView = view
    window.visibleForTest = true
    view.requestAlignment()
    window.visibleForTest = false
    await drainMainQueue()
    XCTAssertEqual(moves, 0)
    window.visibleForTest = true
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    await drainMainQueue()
    XCTAssertEqual(moves, 1, "Reopening must still work after a skipped callback")
    window.contentView = nil
  }

  @MainActor
  func testReattachmentDiscardsOldCallbackAndObserver() async {
    _ = NSApplication.shared
    var reported: [NSWindow] = []
    let view = WindowReportingView { reported.append($0) }
    let oldWindow = makeWindow()
    let newWindow = makeWindow()
    oldWindow.visibleForTest = true
    oldWindow.contentView = view
    oldWindow.contentView = nil
    newWindow.visibleForTest = true
    newWindow.contentView = view
    await drainMainQueue()
    XCTAssertEqual(reported.count, 1)
    XCTAssertTrue(reported.first === newWindow)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: oldWindow)
    await drainMainQueue()
    XCTAssertEqual(reported.count, 1)
    newWindow.contentView = nil
  }

  @MainActor
  private func makeWindow() -> LifecycleTestWindow {
    LifecycleTestWindow(contentRect: NSRect(x: 50, y: 50, width: 386, height: 371),
                        styleMask: .borderless, backing: .buffered, defer: false)
  }

  @MainActor
  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }
}

@MainActor
private final class LifecycleTestWindow: NSWindow {
  var visibleForTest = false
  override var isVisible: Bool { visibleForTest }
}
