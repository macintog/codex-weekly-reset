import AppKit
import SwiftUI
import XCTest
@testable import CodexWeeklyReset

final class PopoverMeasurementTests: XCTestCase {
  @MainActor
  func testContentSizeUsesNativeFrameOverrideForPlacement() {
    _ = NSApplication.shared
    let window = PlacementTestWindow(
      contentRect: NSRect(x: 20, y: 20, width: 386, height: 574),
      styleMask: .borderless, backing: .buffered, defer: false
    )
    window.nativeOriginForTest = NSPoint(x: 120, y: 200)
    window.setContentSize(NSSize(width: 386, height: 371))
    XCTAssertEqual(window.frame.origin, NSPoint(x: 120, y: 200),
                   "AppKit must dispatch through the host's frame override")
    XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size,
                   NSSize(width: 386, height: 371))
  }

  @MainActor
  func testMeasurementExcludesOversizedNativeProposalAndTracksContentChanges() async throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: specimen(height: 335))
    host.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 386, height: 574),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }

    for height in [CGFloat(335), 420, 300, 335] {
      host.rootView = specimen(height: height)
      host.frame = NSRect(x: 0, y: 0, width: 386, height: 574)
      host.layoutSubtreeIfNeeded()
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
      host.layoutSubtreeIfNeeded()
      let reader = try XCTUnwrap(findReader(in: host))
      let size = try XCTUnwrap(reader.measuredContentSize)
      XCTAssertEqual(size.width, 386, accuracy: 0.5)
      XCTAssertEqual(size.height, height + 36, accuracy: 0.5,
                     "Measure app padding once, excluding native flexible space")
    }
  }

  @MainActor
  private func findReader(in view: NSView) -> WindowReportingView? {
    if let reader = view as? WindowReportingView { return reader }
    return view.subviews.lazy.compactMap { self.findReader(in: $0) }.first
  }

  @MainActor
  private func specimen(height: CGFloat) -> some View {
    Color.clear.frame(height: height)
      .padding(18)
      .frame(width: 386)
      .modifier(PopoverContentMeasurement())
      // Model the flexible wrapper in the native menu-bar host.
      .frame(maxHeight: .infinity)
  }
}

@MainActor
private final class PlacementTestWindow: NSWindow {
  var nativeOriginForTest: NSPoint?

  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    var frame = frameRect
    if let nativeOriginForTest { frame.origin = nativeOriginForTest }
    super.setFrame(frame, display: flag)
  }
}
