import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    AppServices.monitor.start()
    PopoverDiagnostics.record("launch")
    DispatchQueue.main.async {
      PopoverAnchorController.shared.captureStatusItemWindow()
    }
  }
}

@MainActor
enum AppServices {
  static let monitor = LimitMonitor.live()
  static let updater = AppUpdater()
}

@MainActor
@main
struct CodexWeeklyResetApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var monitor: LimitMonitor
  @StateObject private var updater: AppUpdater

  init() {
    let monitor = AppServices.monitor
    let updater = AppServices.updater
    _monitor = StateObject(wrappedValue: monitor)
    _updater = StateObject(wrappedValue: updater)
  }

  var body: some Scene {
    MenuBarExtra {
      StatusPopoverView(monitor: monitor, updater: updater)
    } label: {
      MenuBarStatusLabel(state: monitor.state, isRefreshing: monitor.isRefreshing)
    }
    .menuBarExtraStyle(.window)
  }
}
