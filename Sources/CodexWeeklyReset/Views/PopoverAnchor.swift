import AppKit
import OSLog
import SwiftUI

@MainActor
final class PopoverAnchorController {
  static let shared = PopoverAnchorController()

  private weak var statusItemWindow: NSWindow?
  private let logger = Logger(subsystem: "com.macintog.codexweeklyreset", category: "PopoverAnchor")

  func captureStatusItemWindow(excluding excludedWindow: NSWindow? = nil) {
    let candidates = NSApp.windows.filter {
      $0 !== excludedWindow
        && $0.level == .statusBar
        && $0.frame.height <= 64
        && $0.isVisible
    }
    // Preserve the weak launch-time fallback when no visible candidate is
    // available, but never choose between ambiguous candidates.
    guard candidates.count <= 1 else {
      statusItemWindow = nil
      return
    }
    guard let window = candidates.first else { return }

    statusItemWindow = window
    logger.info("Captured status item left edge \(window.frame.minX, privacy: .public)")
  }

  func alignPopoverWindow(_ popoverWindow: NSWindow) {
    guard popoverWindow.isVisible else { return }
    PopoverDiagnostics.record("alignment-request", window: popoverWindow)
    guard !PopoverDiagnostics.nativePositioning else { return }
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
    PopoverDiagnostics.record("aligned", window: popoverWindow)
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
    }
  }

  func updateNSView(_ nsView: WindowReportingView, context: Context) {
    nsView.requestAlignment()
  }
}

@MainActor
final class WindowReportingView: NSView {
  private let report: @MainActor (NSWindow) -> Void
  private var observers: [NSObjectProtocol] = []
  private var attachmentGeneration = 0
  private var alignmentPending = false

  init(report: @escaping @MainActor (NSWindow) -> Void) {
    self.report = report
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attachmentGeneration += 1
    alignmentPending = false
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    guard let window else { return }
    PopoverDiagnostics.record("attached", window: window)

    // SwiftUI owns presentation and its native frame. Attachment can happen while
    // that frame is provisional; wait for presentation before applying our X offset.
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification,
                 NSWindow.didChangeScreenNotification] {
      observers.append(NotificationCenter.default.addObserver(
        forName: name, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.requestAlignment()
        }
      })
    }
    requestAlignment()
  }

  func requestAlignment() {
    guard let window, window.isVisible, !alignmentPending else { return }
    alignmentPending = true
    let generation = attachmentGeneration
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, self.attachmentGeneration == generation else { return }
      self.alignmentPending = false
      guard let window, self.window === window, window.isVisible else { return }
      self.report(window)
    }
  }
}
