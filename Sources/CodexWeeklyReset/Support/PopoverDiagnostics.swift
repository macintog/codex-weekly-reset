import AppKit
import OSLog

/// Explicit, local debug capture: no account, quota, or path contents are recorded.
@MainActor
enum PopoverDiagnostics {
  private static let logger = Logger(subsystem: "com.macintog.codexweeklyreset", category: "PopoverSizing")
  private static var growthNoticeCount = 0
  private static var reportedInsets = false

  static func recordHeightIncrease(
    window: NSWindow, previousFrame: NSRect?, measuredContentSize: CGSize?,
    previousMeasuredContentSize: CGSize?
  ) {
    guard let previousFrame, let measuredContentSize,
          measuredContentSize == previousMeasuredContentSize,
          window.frame.height - previousFrame.height > 0.5 / max(1, window.backingScaleFactor),
          growthNoticeCount < 3 else { return }
    growthNoticeCount += 1
    let oldHeight = previousFrame.height
    let newHeight = window.frame.height
    let screen = window.screen.map { NSStringFromRect($0.frame) } ?? "none"
    logger.notice("Unchanged-content height increase: old=\(oldHeight, privacy: .public) new=\(newHeight, privacy: .public) measured=\(measuredContentSize.height, privacy: .public) visible=\(window.isVisible, privacy: .public) screen=\(screen, privacy: .public) scale=\(window.backingScaleFactor, privacy: .public)")
    if growthNoticeCount == 1 {
      let stack = Thread.callStackSymbols.prefix(12).joined(separator: "\n")
      logger.notice("First unchanged-content growth stack: \(stack, privacy: .public)")
    }
  }

  static func recordUnexpectedInsets(window: NSWindow) {
    guard !reportedInsets, let host = window.contentView else { return }
    let insets = host.safeAreaInsets
    guard insets.top != 0 || insets.bottom != 0 || insets.left != 0 || insets.right != 0 else { return }
    reportedInsets = true
    logger.notice("Popover host has nonzero safe-area insets: top=\(insets.top, privacy: .public) bottom=\(insets.bottom, privacy: .public) left=\(insets.left, privacy: .public) right=\(insets.right, privacy: .public); verify content fitting before adding inset compensation")
  }
  #if DEBUG
  private static var capturedGrowthStacks = 0
  #endif
  static var nativePositioning: Bool {
    #if DEBUG
    ProcessInfo.processInfo.arguments.contains("--native-popover")
    #else
    false
    #endif
  }

  static func record(
    _ event: String,
    window: NSWindow? = nil,
    contentProbe: NSView? = nil,
    measuredContentSize: CGSize? = nil,
    previousFrame: NSRect? = nil,
    captureStack: Bool = false
  ) {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--popover-diagnostics"),
          arguments.indices.contains(index + 1) else { return }
    let path = arguments[index + 1]
    var record: [String: Any] = [
      "event": event, "time": Date().timeIntervalSince1970,
      "uptime": ProcessInfo.processInfo.systemUptime,
      "pid": ProcessInfo.processInfo.processIdentifier,
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "test",
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "nativePositioning": nativePositioning,
      "activationPolicy": NSApp.activationPolicy().rawValue
    ]
    if let measuredContentSize {
      record["measuredContentSize"] = NSStringFromSize(measuredContentSize)
    }
    if let previousFrame {
      record["previousFrame"] = NSStringFromRect(previousFrame)
    }
    // Capture at the resize notification, not after dispatching a correction.
    // Bound symbolication cost even if a native sizing loop is encountered.
    if captureStack, capturedGrowthStacks < 8 {
      capturedGrowthStacks += 1
      record["heightIncreaseStack"] = Array(Thread.callStackSymbols.prefix(32))
    }
    record["statusWindows"] = NSApp.windows.filter { $0.frame.height <= 64 }.map {
      ["class": String(describing: type(of: $0)), "frame": NSStringFromRect($0.frame),
       "level": $0.level.rawValue, "visible": $0.isVisible] as [String: Any]
    }
    if let window {
      record["window"] = window.windowNumber
      record["windowClass"] = String(describing: type(of: window))
      record["frame"] = NSStringFromRect(window.frame)
      record["contentBounds"] = window.contentView.map { NSStringFromRect($0.bounds) }
      record["visible"] = window.isVisible
      record["key"] = window.isKeyWindow
      record["opaque"] = window.isOpaque
      record["shadow"] = window.hasShadow
      record["styleMask"] = window.styleMask.rawValue
      record["screenFrame"] = window.screen.map { NSStringFromRect($0.frame) }
      record["backingScale"] = window.backingScaleFactor
      record["contentRect"] = NSStringFromRect(window.contentRect(forFrameRect: window.frame))
      if let contentProbe, contentProbe.window === window,
         let host = window.contentView {
        // Read geometry already assigned by layout; do not request fitting or
        // another layout pass while diagnosing a possible sizing feedback loop.
        record["probeBounds"] = NSStringFromRect(contentProbe.bounds)
        record["probeRectInHost"] = NSStringFromRect(contentProbe.convert(contentProbe.bounds, to: host))
        let insets = host.safeAreaInsets
        record["hostSafeAreaInsets"] = [
          "top": insets.top, "bottom": insets.bottom,
          "left": insets.left, "right": insets.right
        ]
      }
    }
    guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
    data.append(0x0a)
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    defer { try? handle.close() }
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } catch {
      // Optional diagnostics must never interrupt presentation.
    }
    #endif
  }
}
