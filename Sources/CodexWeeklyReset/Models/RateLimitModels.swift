import Foundation

struct RateLimitWindow: Codable, Equatable, Sendable {
  let usedPercent: Double
  let windowDurationMins: Int
  let resetsAt: TimeInterval

  var remainingPercent: Double {
    min(100, max(0, 100 - usedPercent))
  }

  var resetDate: Date {
    Date(timeIntervalSince1970: resetsAt)
  }
}

struct RateLimitCredits: Codable, Equatable, Sendable {
  let hasCredits: Bool?
  let unlimited: Bool?
  let balance: String?
}

struct RateLimitResetCredit: Codable, Equatable, Sendable {
  let id: String?
  let resetType: String?
  let status: String?
  let grantedAt: TimeInterval?
  let expiresAt: TimeInterval?
  let title: String?
  let description: String?

  var grantedDate: Date? {
    grantedAt.map(Date.init(timeIntervalSince1970:))
  }

  var expiryDate: Date? {
    expiresAt.map(Date.init(timeIntervalSince1970:))
  }

  var isAvailable: Bool {
    status == "available"
  }
}

struct RateLimitResetCredits: Codable, Equatable, Sendable {
  let availableCount: Int
  let credits: [RateLimitResetCredit]?

  init(availableCount: Int, credits: [RateLimitResetCredit]? = nil) {
    self.availableCount = availableCount
    self.credits = credits
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    availableCount = try container.decodeIfPresent(Int.self, forKey: .availableCount) ?? 0
    credits = try container.decodeIfPresent([RateLimitResetCredit].self, forKey: .credits)
  }

  var earliestAvailableExpiry: Date? {
    credits?
      .filter(\.isAvailable)
      .compactMap(\.expiryDate)
      .min()
  }

  private enum CodingKeys: String, CodingKey {
    case availableCount
    case credits
  }
}

struct RateLimitBucket: Codable, Equatable, Sendable {
  let limitId: String
  let limitName: String?
  let primary: RateLimitWindow?
  let secondary: RateLimitWindow?
  let credits: RateLimitCredits?
  let planType: String?
  let rateLimitReachedType: String?

  var weeklyWindow: RateLimitWindow? {
    let weeklyDurationMins = 7 * 24 * 60

    if let secondary, secondary.windowDurationMins == weeklyDurationMins {
      return secondary
    }
    if let primary, primary.windowDurationMins == weeklyDurationMins {
      return primary
    }

    // Older app-server versions consistently placed the weekly window in
    // secondary, even when the reported duration was not exactly seven days.
    return secondary
  }
}

struct RateLimitsEnvelope: Codable, Equatable, Sendable {
  let rateLimits: RateLimitBucket?
  let rateLimitsByLimitId: [String: RateLimitBucket]?
  let rateLimitResetCredits: RateLimitResetCredits?
}

struct RateLimitSnapshot: Codable, Equatable, Sendable {
  let limitId: String
  let limitName: String?
  let usedPercent: Double
  let remainingPercent: Double
  let windowDurationMins: Int
  let resetsAt: Date
  let checkedAt: Date
  let planType: String?
  let sourcePath: String
  let resetCredits: RateLimitResetCredits?

  var remainingRounded: Int {
    Int(remainingPercent.rounded())
  }

  var usedRounded: Int {
    Int(usedPercent.rounded())
  }

  func withResetCredits(_ resetCredits: RateLimitResetCredits?) -> RateLimitSnapshot {
    RateLimitSnapshot(
      limitId: limitId,
      limitName: limitName,
      usedPercent: usedPercent,
      remainingPercent: remainingPercent,
      windowDurationMins: windowDurationMins,
      resetsAt: resetsAt,
      checkedAt: checkedAt,
      planType: planType,
      sourcePath: sourcePath,
      resetCredits: resetCredits
    )
  }

  static func mainCodexWeekly(
    from envelope: RateLimitsEnvelope,
    checkedAt: Date = Date(),
    sourcePath: String
  ) throws -> RateLimitSnapshot {
    let bucket = envelope.rateLimitsByLimitId?["codex"] ?? {
      guard envelope.rateLimits?.limitId == "codex" else {
        return nil
      }
      return envelope.rateLimits
    }()

    guard let bucket else {
      throw RateLimitSelectionError.missingMainCodexBucket
    }

    guard let weekly = bucket.weeklyWindow else {
      throw RateLimitSelectionError.missingWeeklyWindow
    }

    return RateLimitSnapshot(
      limitId: bucket.limitId,
      limitName: bucket.limitName,
      usedPercent: weekly.usedPercent,
      remainingPercent: weekly.remainingPercent,
      windowDurationMins: weekly.windowDurationMins,
      resetsAt: weekly.resetDate,
      checkedAt: checkedAt,
      planType: bucket.planType,
      sourcePath: sourcePath,
      resetCredits: envelope.rateLimitResetCredits
    )
  }
}

enum RateLimitSelectionError: LocalizedError, Equatable {
  case missingMainCodexBucket
  case missingWeeklyWindow

  var errorDescription: String? {
    switch self {
    case .missingMainCodexBucket:
      return "The main Codex limit bucket was not returned."
    case .missingWeeklyWindow:
      return "The main Codex bucket did not include a weekly window."
    }
  }
}

enum NotificationPermissionState: String, Codable, Equatable, Sendable {
  case notDetermined
  case denied
  case authorized
  case provisional
  case unknown

  var displayName: String {
    switch self {
    case .notDetermined:
      return "Setting up"
    case .denied:
      return "Denied"
    case .authorized:
      return "Allowed"
    case .provisional:
      return "Provisional"
    case .unknown:
      return "Unknown"
    }
  }
}

enum MonitorState: Equatable {
  case idle
  case loading
  case ready(RateLimitSnapshot)
  case failed(String)

  var snapshot: RateLimitSnapshot? {
    guard case let .ready(snapshot) = self else {
      return nil
    }
    return snapshot
  }
}
