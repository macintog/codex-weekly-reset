import Foundation

enum QuotaIndicatorSlots {
  static let totalSlots = 9

  static func filledSlots(forRemainingPercent remainingPercent: Double) -> Int {
    let fraction = min(1, max(0, remainingPercent / 100))

    if fraction <= 0 {
      return 0
    }

    return min(totalSlots, max(1, Int((fraction * Double(totalSlots)).rounded(.up))))
  }

  static func band(forRemainingPercent remainingPercent: Double) -> QuotaIndicatorBand {
    QuotaIndicatorBand(filledSlots: filledSlots(forRemainingPercent: remainingPercent))
  }
}

enum QuotaIndicatorBand: Equatable {
  case unknown
  case healthy
  case caution
  case alarm
  case failed

  init(filledSlots: Int) {
    if filledSlots <= 1 {
      self = .alarm
    } else if filledSlots == 2 {
      self = .caution
    } else {
      self = .healthy
    }
  }
}
