import AppKit

/// Explicit, local debug capture: no account, quota, or path contents are recorded.
@MainActor
enum PopoverDiagnostics {
  static var nativePositioning: Bool {
    #if DEBUG
    ProcessInfo.processInfo.arguments.contains("--native-popover")
    #else
    false
    #endif
  }

  static func record(_ event: String, window: NSWindow? = nil) {
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
