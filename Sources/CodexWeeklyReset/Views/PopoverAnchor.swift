import AppKit
import OSLog
import SwiftUI

@MainActor
final class PopoverAnchorController {
  static let shared = PopoverAnchorController()

  private weak var statusItemWindow: NSWindow?
  private let logger = Logger(subsystem: "com.macintog.codexweeklyreset", category: "PopoverAnchor")

  func captureStatusItemWindow(excluding excludedWindow: NSWindow? = nil) {
    guard let window = NSApp.windows.first(where: {
      $0 !== excludedWindow
        && $0.level == .statusBar
        && $0.frame.height <= 64
        && $0.isVisible
    }) else {
      return
    }

    statusItemWindow = window
    logger.info("Captured status item left edge \(window.frame.minX, privacy: .public)")
  }

  func alignPopoverWindow(_ popoverWindow: NSWindow) {
    captureStatusItemWindow(excluding: popoverWindow)
    guard let statusItemWindow,
          statusItemWindow !== popoverWindow,
          let screen = statusItemWindow.screen ?? popoverWindow.screen else {
      return
    }

    let targetX = PopoverAnchorGeometry.alignedOriginX(
      statusItemLeft: statusItemWindow.frame.minX,
      popoverWidth: popoverWindow.frame.width,
      screenFrame: screen.frame
    )

    guard abs(popoverWindow.frame.minX - targetX) > 0.5 else {
      return
    }

    popoverWindow.setFrameOrigin(
      NSPoint(x: targetX, y: popoverWindow.frame.minY)
    )
    logger.info(
      "Aligned popover left edge \(targetX, privacy: .public) to status item left edge \(statusItemWindow.frame.minX, privacy: .public)"
    )
  }
}

enum PopoverAnchorGeometry {
  static func alignedOriginX(
    statusItemLeft: CGFloat,
    popoverWidth: CGFloat,
    screenFrame: CGRect
  ) -> CGFloat {
    min(
      max(statusItemLeft, screenFrame.minX),
      max(screenFrame.minX, screenFrame.maxX - popoverWidth)
    )
  }
}

struct PopoverWindowReader: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowReportingView {
    WindowReportingView { window in
      PopoverAnchorController.shared.alignPopoverWindow(window)
      DispatchQueue.main.async {
        PopoverAnchorController.shared.alignPopoverWindow(window)
      }
    }
  }

  func updateNSView(_ nsView: WindowReportingView, context: Context) {
    guard let window = nsView.window else {
      return
    }
    PopoverAnchorController.shared.alignPopoverWindow(window)
  }
}

final class WindowReportingView: NSView {
  private let report: @MainActor (NSWindow) -> Void

  init(report: @escaping @MainActor (NSWindow) -> Void) {
    self.report = report
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else {
      return
    }
    report(window)
  }
}
