import Foundation
import OSLog
import UserNotifications

protocol UserNotificationManaging {
  func authorizationStatus() async -> NotificationPermissionState
  func requestAuthorization() async -> NotificationPermissionState
  func notify(_ event: LimitNotificationEvent, previous: RateLimitSnapshot, current: RateLimitSnapshot) async throws
  func notify(_ alert: ResetCreditExpiryAlert, availableCount: Int) async throws
}

final class SystemNotificationService: NSObject, UserNotificationManaging {
  private let center: UNUserNotificationCenter
  private let launchIdentifier: String
  private let logger = Logger(subsystem: "com.macintog.codexweeklyreset", category: "Notifications")

  init(
    center: UNUserNotificationCenter = .current(),
    launchIdentifier: String = UUID().uuidString
  ) {
    self.center = center
    self.launchIdentifier = launchIdentifier
    super.init()
    center.delegate = self
  }

  func authorizationStatus() async -> NotificationPermissionState {
    let settings = await notificationSettings()
    return NotificationPermissionState(settings.authorizationStatus)
  }

  func requestAuthorization() async -> NotificationPermissionState {
    do {
      _ = try await center.requestAuthorization(options: [.alert, .sound])
    } catch {
      return await authorizationStatus()
    }
    return await authorizationStatus()
  }

  func notify(_ event: LimitNotificationEvent, previous: RateLimitSnapshot, current: RateLimitSnapshot) async throws {
    try await requireAuthorization()

    let content = UNMutableNotificationContent()
    content.title = event.title
    content.body = event.body(previous: previous, current: current)
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: "codex-weekly-reset-\(event.rawValue)-\(Int(current.checkedAt.timeIntervalSince1970))",
      content: content,
      trigger: nil
    )

    try await center.add(request)
  }

  func notify(_ alert: ResetCreditExpiryAlert, availableCount: Int) async throws {
    try await requireAuthorization()

    let content = UNMutableNotificationContent()
    content.body = alert.body(availableCount: availableCount)
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: Self.resetExpiryRequestIdentifier(
        for: alert,
        launchIdentifier: launchIdentifier
      ),
      content: content,
      trigger: nil
    )

    try await center.add(request)
    logger.info("Submitted reset-expiry alert \(alert.level.rawValue, privacy: .public) for this launch")
  }

  static func resetExpiryRequestIdentifier(
    for alert: ResetCreditExpiryAlert,
    launchIdentifier: String
  ) -> String {
    "\(alert.notificationIdentifier)-launch-\(launchIdentifier)"
  }

  private func requireAuthorization() async throws {
    guard await authorizationStatus().allowsDelivery else {
      throw NotificationDeliveryError.notAuthorized
    }
  }

  private func notificationSettings() async -> UNNotificationSettings {
    await withCheckedContinuation { continuation in
      center.getNotificationSettings { settings in
        continuation.resume(returning: settings)
      }
    }
  }
}

private enum NotificationDeliveryError: Error {
  case notAuthorized
}

extension SystemNotificationService: UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }
}

struct FixedNotificationService: UserNotificationManaging {
  let state: NotificationPermissionState

  func authorizationStatus() async -> NotificationPermissionState {
    state
  }

  func requestAuthorization() async -> NotificationPermissionState {
    state
  }

  func notify(_ event: LimitNotificationEvent, previous: RateLimitSnapshot, current: RateLimitSnapshot) async throws {}

  func notify(_ alert: ResetCreditExpiryAlert, availableCount: Int) async throws {}
}

private extension NotificationPermissionState {
  init(_ status: UNAuthorizationStatus) {
    switch status {
    case .notDetermined:
      self = .notDetermined
    case .denied:
      self = .denied
    case .authorized:
      self = .authorized
    case .provisional:
      self = .provisional
    @unknown default:
      self = .unknown
    }
  }
}
