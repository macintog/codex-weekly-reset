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
  func testMeasuredContentRepairsOversizedWindowAndFollowsGrowShrink() async {
    _ = NSApplication.shared
    let window = makeWindow()
    window.setFrame(NSRect(x: 50, y: 50, width: 386, height: 574), display: false)
    let view = WindowReportingView { _ in }
    window.contentView = view
    view.updateContentSize(CGSize(width: 386, height: 371))
    await drainMainQueue()
    XCTAssertEqual(window.fitCount, 0, "Hidden windows retain native presentation ownership")
    window.visibleForTest = true
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    await drainMainQueue()
    XCTAssertEqual(window.frame.size, CGSize(width: 386, height: 371))
    XCTAssertEqual(window.fitCount, 1)
    await drainMainQueue()
    XCTAssertEqual(window.fitCount, 1, "Own resize notifications must not recursively resize")

    view.updateContentSize(CGSize(width: 386, height: 430))
    await drainMainQueue()
    XCTAssertEqual(window.frame.height, 430)
    view.updateContentSize(CGSize(width: 386, height: 350))
    await drainMainQueue()
    XCTAssertEqual(window.frame.height, 350)
    window.contentView = nil
  }

  @MainActor
  func testReopenScreenBackingAndExternalResizeRecoverUnchangedContent() async {
    _ = NSApplication.shared
    let window = makeWindow()
    let view = WindowReportingView { _ in }
    window.contentView = view
    view.updateContentSize(CGSize(width: 386, height: 371))
    for event in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification,
                  NSWindow.didChangeBackingPropertiesNotification, NSWindow.didResizeNotification] {
      window.visibleForTest = false
      window.setFrame(NSRect(x: 50, y: 50, width: 386, height: 574), display: false)
      window.visibleForTest = true
      NotificationCenter.default.post(name: event, object: window)
      await drainMainQueue()
      XCTAssertEqual(window.frame.height, 371, "Recovery event: \(event.rawValue)")
    }
    XCTAssertEqual(window.fitCount, 4)
    window.contentView = nil
  }

  @MainActor
  func testInvalidAndDetachedMeasurementCannotResizeWindow() async {
    _ = NSApplication.shared
    let window = makeWindow()
    window.visibleForTest = true
    let view = WindowReportingView { _ in }
    window.contentView = view
    view.updateContentSize(CGSize(width: 386, height: CGFloat.nan))
    await drainMainQueue()
    XCTAssertEqual(window.fitCount, 0)
    view.updateContentSize(CGSize(width: 386, height: 450))
    window.contentView = nil
    await drainMainQueue()
    XCTAssertEqual(window.fitCount, 0, "Queued measurement must not apply after detachment")
  }

  @MainActor
  func testRejectedNativeSizeDoesNotLoopUntilNewPresentation() async {
    _ = NSApplication.shared
    let window = makeWindow()
    window.rejectFit = true
    window.visibleForTest = true
    let view = WindowReportingView { _ in }
    window.contentView = view
    view.updateContentSize(CGSize(width: 386, height: 450))
    await drainMainQueue()
    XCTAssertEqual(window.fitCount, 1)
    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
    await drainMainQueue()
    XCTAssertEqual(window.fitCount, 1)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    await drainMainQueue()
    XCTAssertEqual(window.fitCount, 2, "New presentation permits a new native sizing attempt")
    window.contentView = nil
  }

  @MainActor
  func testDeferredNativePushbackHasBoundedCorrections() async {
    _ = NSApplication.shared
    let window = makeWindow()
    window.setFrame(NSRect(x: 50, y: 50, width: 386, height: 574), display: false)
    window.visibleForTest = true
    let view = WindowReportingView { _ in }
    window.contentView = view
    view.updateContentSize(CGSize(width: 386, height: 371))
    await drainMainQueue()
    XCTAssertEqual(window.frame.height, 371)
    XCTAssertEqual(window.fitCount, 1)

    // Model a native asynchronous resize after setContentSize has returned
    // successfully. One correction remains for ordinary external corruption.
    window.setFrame(NSRect(x: 50, y: 50, width: 386, height: 574), display: false)
    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
    await drainMainQueue()
    XCTAssertEqual(window.frame.height, 371)
    XCTAssertEqual(window.fitCount, 2)

    for _ in 0..<4 {
      window.setFrame(NSRect(x: 50, y: 50, width: 386, height: 574), display: false)
      NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
      await drainMainQueue()
    }
    XCTAssertEqual(window.fitCount, 2, "Repeated native pushback must not keep fighting the host")
    XCTAssertEqual(window.frame.height, 574)

    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    await drainMainQueue()
    XCTAssertEqual(window.frame.height, 371)
    XCTAssertEqual(window.fitCount, 3, "A new presentation restores the recovery budget")
    window.contentView = nil
  }

  func testFittingGeometryBoundsAndPixelTolerance() {
    let maximum = CGSize(width: 500, height: 600)
    XCTAssertEqual(PopoverContentGeometry.targetSize(measured: CGSize(width: 386, height: 700), maximum: maximum, scale: 2),
                   CGSize(width: 386, height: 600))
    XCTAssertEqual(PopoverContentGeometry.targetSize(measured: CGSize(width: 386, height: 371.1), maximum: maximum, scale: 2),
                   CGSize(width: 386, height: 371.5))
    for invalid in [CGFloat.nan, .infinity, 0, -1] {
      XCTAssertNil(PopoverContentGeometry.targetSize(measured: CGSize(width: 386, height: invalid), maximum: maximum, scale: 2))
    }
    XCTAssertFalse(PopoverContentGeometry.differs(CGSize(width: 386, height: 371), CGSize(width: 386, height: 371.2), scale: 2))
    XCTAssertTrue(PopoverContentGeometry.differs(CGSize(width: 386, height: 371), CGSize(width: 386, height: 371.3), scale: 2))
  }

  @MainActor
  func testNonKeyOcclusionPresentationFitsAndOnlyNewVisibilityResetsBudget() async {
    _ = NSApplication.shared
    let window = makeWindow()
    window.setFrame(NSRect(x: 50, y: 50, width: 386, height: 574), display: false)
    let view = WindowReportingView { _ in }
    window.contentView = view
    view.updateContentSize(CGSize(width: 386, height: 371))
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    await drainMainQueue()
    XCTAssertEqual(window.fitCount, 0)

    window.visibleForTest = true
    window.occlusionVisibleForTest = true
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    await drainMainQueue()
    XCTAssertFalse(window.isKeyWindow)
    XCTAssertEqual(window.frame.height, 371)
    XCTAssertEqual(window.fitCount, 1)

    // Repeated visible notifications must not replenish the bounded budget.
    for _ in 0..<3 {
      window.setFrame(NSRect(x: 50, y: 50, width: 386, height: 574), display: false)
      NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
      await drainMainQueue()
    }
    XCTAssertEqual(window.fitCount, 2)
    XCTAssertEqual(window.frame.height, 574)

    window.visibleForTest = false
    window.occlusionVisibleForTest = false
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    await drainMainQueue()
    XCTAssertEqual(window.fitCount, 2, "Hidden occlusion event must not fit")
    window.visibleForTest = true
    window.occlusionVisibleForTest = true
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    await drainMainQueue()
    XCTAssertEqual(window.fitCount, 3)
    XCTAssertEqual(window.frame.height, 371)
    window.contentView = nil
  }

  @MainActor
  private func makeWindow() -> LifecycleTestWindow {
    let window = LifecycleTestWindow(contentRect: NSRect(x: 50, y: 50, width: 386, height: 371),
                                     styleMask: .borderless, backing: .buffered, defer: false)
    window.fitCount = 0
    return window
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
  var occlusionVisibleForTest = false
  override var occlusionState: NSWindow.OcclusionState { occlusionVisibleForTest ? [.visible] : [] }
  var fitCount = 0
  var rejectFit = false
  override var screen: NSScreen? { NSScreen.screens.first }
  override func setContentSize(_ size: NSSize) {
    fitCount += 1
    if !rejectFit { super.setContentSize(size) }
    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: self)
  }
  override var isVisible: Bool { visibleForTest }
}
