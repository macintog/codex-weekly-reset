import Foundation

enum LimitNotificationPolicy {
  static let lowQuotaThreshold = 20.0
  static let redQuotaThreshold = 10.0

  static func event(
    previous: RateLimitSnapshot?,
    current: RateLimitSnapshot
  ) -> LimitNotificationEvent? {
    guard let previous else {
      return nil
    }

    if current.remainingPercent <= 0, previous.remainingPercent > 0 {
      return .quotaExhausted
    }

    if current.remainingPercent < redQuotaThreshold, previous.remainingPercent >= redQuotaThreshold {
      return .redQuota
    }

    if current.remainingPercent <= lowQuotaThreshold, previous.remainingPercent > lowQuotaThreshold {
      return .lowQuota
    }

    let previousSlots = QuotaIndicatorSlots.filledSlots(forRemainingPercent: previous.remainingPercent)
    let currentSlots = QuotaIndicatorSlots.filledSlots(forRemainingPercent: current.remainingPercent)

    if currentSlots > previousSlots {
      return .quotaIncreased
    }

    return nil
  }

  static func shouldNotifyIncrease(
    previous: RateLimitSnapshot?,
    current: RateLimitSnapshot
  ) -> Bool {
    event(previous: previous, current: current) == .quotaIncreased
  }
}

enum LimitNotificationEvent: String, Equatable, Sendable {
  case lowQuota
  case redQuota
  case quotaExhausted
  case quotaIncreased

  var title: String {
    switch self {
    case .lowQuota:
      return "Codex weekly quota is low"
    case .redQuota:
      return "Codex weekly quota is low"
    case .quotaExhausted:
      return "Codex weekly limit exhausted"
    case .quotaIncreased:
      return "Codex weekly quota increased"
    }
  }

  func body(previous: RateLimitSnapshot, current: RateLimitSnapshot) -> String {
    let remaining = DisplayFormatters.percentage(current.remainingPercent)

    switch self {
    case .lowQuota:
      return "Less than 20% remaining."
    case .redQuota:
      return "Less than 10% remaining."
    case .quotaExhausted:
      return "Reset is in \(resetDurationText(from: current.checkedAt, to: current.resetsAt))."
    case .quotaIncreased:
      return "Weekly remaining is now \(remaining)."
    }
  }

  private func resetDurationText(from start: Date, to end: Date) -> String {
    let seconds = max(0, end.timeIntervalSince(start))
    let totalHours = Int(seconds / 3_600)

    guard totalHours > 0 else {
      return "less than 1 hour"
    }

    let days = totalHours / 24
    let hours = totalHours % 24
    var parts: [String] = []

    if days > 0 {
      parts.append("\(days) \(days == 1 ? "day" : "days")")
    }

    if hours > 0 {
      parts.append("\(hours) \(hours == 1 ? "hour" : "hours")")
    }

    return parts.joined(separator: " ")
  }
}

struct ResetCreditExpiryAlert: Equatable, Hashable, Sendable {
  enum Level: String, Equatable, Hashable, Sendable {
    case warning
    case critical
  }

  let level: Level
  let expiry: Date

  var notificationIdentifier: String {
    "codex-weekly-reset-reset-expiry-\(level.rawValue)-\(Int(expiry.timeIntervalSince1970))"
  }

  func body(availableCount: Int, now: Date = Date()) -> String {
    let expiryText = DisplayFormatters.alertResetDayAndTime(expiry, now: now)

    switch level {
    case .warning:
      let noun = availableCount == 1 ? "reset" : "resets"
      return "One of your \(availableCount) banked \(noun) expires \(expiryText)."
    case .critical:
      return "Use the reset before \(expiryText) to avoid losing it."
    }
  }
}

enum ResetCreditExpiryPolicy {
  static let warningInterval: TimeInterval = 24 * 60 * 60
  static let criticalInterval: TimeInterval = 60 * 60

  static func alert(
    resetCredits: RateLimitResetCredits?,
    now: Date
  ) -> ResetCreditExpiryAlert? {
    guard let expiry = resetCredits?.earliestAvailableExpiry else {
      return nil
    }

    let remaining = expiry.timeIntervalSince(now)
    guard remaining > 0 else {
      return nil
    }

    if remaining <= criticalInterval {
      return ResetCreditExpiryAlert(level: .critical, expiry: expiry)
    }

    if remaining <= warningInterval {
      return ResetCreditExpiryAlert(level: .warning, expiry: expiry)
    }

    return nil
  }
}
