import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    AppServices.monitor.start()
  }
}

@MainActor
enum AppServices {
  static let monitor = LimitMonitor.live()
}

@MainActor
@main
struct CodexWeeklyResetApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var monitor: LimitMonitor

  init() {
    let monitor = AppServices.monitor
    _monitor = StateObject(wrappedValue: monitor)
  }

  var body: some Scene {
    MenuBarExtra {
      StatusPopoverView(monitor: monitor)
    } label: {
      MenuBarStatusLabel(state: monitor.state, isRefreshing: monitor.isRefreshing)
    }
    .menuBarExtraStyle(.window)
  }
}
