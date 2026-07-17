import Foundation

enum DisplayFormatters {
  static let time: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()

  static let reset: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  static let resetDayAndTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE 'at' h:mm a"
    return formatter
  }()

  static let resetTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  static func alertResetDayAndTime(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    let day: String

    if calendar.isDate(date, inSameDayAs: now) {
      day = "today"
    } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              calendar.isDate(date, inSameDayAs: tomorrow) {
      day = "tomorrow"
    } else {
      return resetDayAndTime.string(from: date)
    }

    return "\(day) at \(resetTime.string(from: date))"
  }

  static func percentage(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
  }

  static func shortPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) {
      return "~" + path.dropFirst(home.count)
    }
    return path
  }

  static func sourceLabel(_ source: String) -> String {
    if source.hasPrefix("Fixture:") {
      return "Fixture"
    }

    return shortPath(source)
  }
}
