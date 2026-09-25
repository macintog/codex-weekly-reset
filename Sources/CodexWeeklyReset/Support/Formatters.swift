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

  static func alertResetDayAndTime(
    _ date: Date,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent,
    locale: Locale = .autoupdatingCurrent
  ) -> String {
    bankedResetExpiryDayAndTime(date, now: now, calendar: calendar, locale: locale)
  }

  static func bankedResetExpiryDayAndTime(
    _ date: Date,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent,
    locale: Locale = .autoupdatingCurrent
  ) -> String {
    let time = localizedTime(date, calendar: calendar, locale: locale)
    let day: String
    if calendar.isDate(date, inSameDayAs: now) {
      day = "today"
    } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
              calendar.isDate(date, inSameDayAs: tomorrow) {
      day = "tomorrow"
    } else {
      let sameYear = calendar.component(.era, from: date) == calendar.component(.era, from: now)
        && calendar.component(.year, from: date) == calendar.component(.year, from: now)
      day = localizedDatePart(
        sameYear ? "EEEMMMd" : "yEEEMMMd",
        date: date, calendar: calendar, locale: locale
      )
    }
    return "\(day) at \(time)"
  }

  static func weeklyResetText(_ date: Date, now: Date = Date()) -> String {
    let prefix = date > now ? "Resets " : "Reset was scheduled "
    return prefix + alertResetDayAndTime(date, now: now)
  }

  private static func localizedDatePart(
    _ template: String,
    date: Date,
    calendar: Calendar,
    locale: Locale
  ) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
  }

  private static func localizedTime(
    _ date: Date,
    calendar: Calendar,
    locale: Locale
  ) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone
    formatter.timeStyle = .short
    return formatter.string(from: date)
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
