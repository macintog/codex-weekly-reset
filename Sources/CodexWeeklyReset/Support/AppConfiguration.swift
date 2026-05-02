import Foundation

struct AppConfiguration: Equatable {
  let configuredCodexPath: String?
  let fixturePath: String?
  let notificationOverride: NotificationPermissionState?
  let pollInterval: TimeInterval
  let disableCodexFallbacks: Bool

  static func live(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> AppConfiguration {
    let configuredPath = argumentValue("--codex-path", in: arguments)
      ?? environment["CODEX_WEEKLY_RESET_CODEX_PATH"]

    let fixturePath = argumentValue("--fixture", in: arguments)
      ?? environment["CODEX_WEEKLY_RESET_FIXTURE"]

    let notificationState = argumentValue("--notification-state", in: arguments)
      ?? environment["CODEX_WEEKLY_RESET_NOTIFICATION_STATE"]

    let intervalText = argumentValue("--poll-interval", in: arguments)
      ?? environment["CODEX_WEEKLY_RESET_POLL_INTERVAL"]

    let disableFallbacks = arguments.contains("--disable-codex-fallbacks")
      || environment["CODEX_WEEKLY_RESET_DISABLE_CODEX_FALLBACKS"] == "1"

    let interval = intervalText.flatMap(TimeInterval.init) ?? 300

    return AppConfiguration(
      configuredCodexPath: configuredPath?.nonEmpty,
      fixturePath: fixturePath?.nonEmpty,
      notificationOverride: notificationState.flatMap(NotificationPermissionState.init(rawValue:)),
      pollInterval: max(5, interval),
      disableCodexFallbacks: disableFallbacks
    )
  }

  private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name) else {
      return nil
    }
    let valueIndex = arguments.index(after: index)
    guard arguments.indices.contains(valueIndex) else {
      return nil
    }
    return arguments[valueIndex]
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
