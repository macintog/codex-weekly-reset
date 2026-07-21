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

  static func bankedResetExpiryDayAndTime(
    _ date: Date,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent,
    locale: Locale = .autoupdatingCurrent
  ) -> String {
    let weekday = localizedDatePart("EEEE", date: date, calendar: calendar, locale: locale)
    let time = localizedTime(date, calendar: calendar, locale: locale)

    if let endOfFirstWeek = calendar.date(byAdding: .day, value: 7, to: now),
       date <= endOfFirstWeek {
      return "\(weekday) at \(time)"
    }

    if let endOfSecondWeek = calendar.date(byAdding: .day, value: 14, to: now),
       date <= endOfSecondWeek {
      return "next \(weekday) at \(time)"
    }

    let monthAndDay = localizedDatePart("Md", date: date, calendar: calendar, locale: locale)
    return "on \(monthAndDay) at \(time)"
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
