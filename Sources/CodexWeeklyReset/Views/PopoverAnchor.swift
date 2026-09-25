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
  var contentSize: CGSize? = nil

  func makeNSView(context: Context) -> WindowReportingView {
    WindowReportingView { window in
      PopoverAnchorController.shared.alignPopoverWindow(window)
    }
  }

  func updateNSView(_ nsView: WindowReportingView, context: Context) {
    nsView.updateContentSize(contentSize)
    nsView.requestAlignment()
  }
}

@MainActor
final class WindowReportingView: NSView {
  private let report: @MainActor (NSWindow) -> Void
  private var observers: [NSObjectProtocol] = []
  private var attachmentGeneration = 0
  // Coalesces both content fitting and the existing horizontal alignment pass.
  private var alignmentPending = false
  private(set) var measuredContentSize: CGSize?
  private var applyingFit = false
  private var lastFit: (target: CGSize, result: CGSize)?
  private var fitAttempts = 0
  private let maximumFitAttempts = 2
  private var previousFrame: NSRect?
  private var previousMeasuredContentSize: CGSize?
  private var wasOcclusionVisible = false
  #if DEBUG
  private static var didInjectExtraHeight = false
  #endif

  func updateContentSize(_ size: CGSize?) {
    guard measuredContentSize != size else { return }
    measuredContentSize = size
    lastFit = nil
    fitAttempts = 0
    requestAlignment()
  }

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
    lastFit = nil
    fitAttempts = 0
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    guard let window else { previousFrame = nil; return }
    previousFrame = window.frame
    previousMeasuredContentSize = measuredContentSize
    wasOcclusionVisible = window.occlusionState.contains(.visible)
    PopoverDiagnostics.record("attached", window: window, contentProbe: self, measuredContentSize: measuredContentSize)

    // SwiftUI owns presentation and its native frame. Attachment can happen while
    // that frame is provisional; wait for presentation before applying our X offset.
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification,
                 NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
                 NSWindow.didChangeOcclusionStateNotification] {
      observers.append(NotificationCenter.default.addObserver(
        forName: name, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          if let self, let window = self.window {
            let oldFrame = self.previousFrame
            let previousMeasuredSize = self.previousMeasuredContentSize
            if name == NSWindow.didResizeNotification, !self.applyingFit {
              PopoverDiagnostics.recordHeightIncrease(
                window: window, previousFrame: oldFrame,
                measuredContentSize: self.measuredContentSize,
                previousMeasuredContentSize: previousMeasuredSize
              )
            }
            PopoverDiagnostics.record(
              name.rawValue, window: window, contentProbe: self,
              measuredContentSize: self.measuredContentSize, previousFrame: oldFrame,
              captureStack: name == NSWindow.didResizeNotification
                && oldFrame.map { window.frame.height > $0.height } == true
            )
            self.previousFrame = window.frame
            self.previousMeasuredContentSize = self.measuredContentSize
          }
          guard let self, !self.applyingFit else { return }
          if name == NSWindow.didChangeOcclusionStateNotification {
            guard let window = self.window else { return }
            let visible = window.occlusionState.contains(.visible)
            let newlyVisible = visible && !self.wasOcclusionVisible
            self.wasOcclusionVisible = visible
            guard window.isVisible, visible else { return }
            if newlyVisible {
              self.lastFit = nil
              self.fitAttempts = 0
            }
          } else if name != NSWindow.didResizeNotification {
            self.lastFit = nil
            self.fitAttempts = 0
          }
          self.requestAlignment()
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
      PopoverDiagnostics.record("content-before-alignment", window: window, contentProbe: self, measuredContentSize: self.measuredContentSize)
      self.fitContent(in: window)
      self.report(window)
    }
  }

  private func fitContent(in window: NSWindow) {
    guard let measuredContentSize,
          let screen = window.screen else { return }
    let screenContent = window.contentRect(forFrameRect: screen.visibleFrame).size
    let maximum = CGSize(
      width: min(screenContent.width, window.contentMaxSize.width),
      height: min(screenContent.height, window.contentMaxSize.height)
    )
    guard let target = PopoverContentGeometry.targetSize(
      measured: measuredContentSize, maximum: maximum, scale: window.backingScaleFactor
    ) else { return }
    PopoverDiagnostics.recordUnexpectedInsets(window: window)
    injectExtraHeightIfRequested(in: window)
    let current = window.contentRect(forFrameRect: window.frame).size
    guard PopoverContentGeometry.differs(current, target, scale: window.backingScaleFactor) else { return }
    // Native hosts may apply stricter limits than the public maximum. Do not
    // repeatedly fight an unchanged native result from our own resize.
    if let lastFit, lastFit.target == target,
       !PopoverContentGeometry.differs(lastFit.result, current, scale: window.backingScaleFactor) {
      return
    }
    // A native host can accept our size and asynchronously restore its own.
    // Resize notifications therefore cannot replenish this budget. One retry
    // allows recovery from an unrelated external resize while continuously open;
    // further disagreement waits for content, presentation, or display changes.
    guard fitAttempts < maximumFitAttempts else { return }
    fitAttempts += 1
    PopoverDiagnostics.record("fit-before", window: window, contentProbe: self, measuredContentSize: measuredContentSize)
    applyingFit = true
    window.setContentSize(target)
    applyingFit = false
    lastFit = (target, window.contentRect(forFrameRect: window.frame).size)
    PopoverDiagnostics.record("fit-after", window: window, contentProbe: self, measuredContentSize: measuredContentSize)
  }

  private func injectExtraHeightIfRequested(in window: NSWindow) {
    #if DEBUG
    guard !Self.didInjectExtraHeight, window.isVisible else { return }
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--popover-test-extra-height"),
          arguments.indices.contains(index + 1),
          let extra = Double(arguments[index + 1]), extra.isFinite,
          extra > 0, extra <= 1_000 else { return }
    let current = window.contentRect(forFrameRect: window.frame).size
    guard current.width.isFinite, current.height.isFinite,
          current.width > 0, current.height > 0 else { return }
    Self.didInjectExtraHeight = true
    applyingFit = true
    window.setContentSize(CGSize(width: current.width, height: current.height + CGFloat(extra)))
    applyingFit = false
    PopoverDiagnostics.record("test-extra-height-injected", window: window,
                              contentProbe: self, measuredContentSize: measuredContentSize)
    #endif
  }

}
