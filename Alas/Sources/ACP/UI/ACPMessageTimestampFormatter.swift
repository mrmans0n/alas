import Foundation

enum ACPMessageTimestampFormatter {
    static func string(
        for date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let format: String
        if calendar.isDate(date, inSameDayAs: now) {
            format = "HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            format = "d MMM, HH:mm"
        } else {
            format = "d MMM yyyy, HH:mm"
        }
        return formatter(format: format, calendar: calendar, locale: locale).string(from: date)
    }

    /// Every transcript row formats its timestamp when it mounts, and building
    /// a `DateFormatter` costs far more than using one. `NSCache` is
    /// thread-safe, and a configured formatter is only read.
    nonisolated(unsafe) private static let formatters = NSCache<NSString, DateFormatter>()

    private static func formatter(format: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let key = "\(format)|\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)" as NSString
        if let cached = formatters.object(forKey: key) { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        formatters.setObject(formatter, forKey: key)
        return formatter
    }
}

enum ACPToolCallDurationFormatter {
    static func string(for duration: TimeInterval, locale: Locale = .current) -> String {
        let seconds = max(0, duration)
        let fractionDigits = seconds < 10 ? 1 : 0
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        let value = formatter.string(from: seconds as NSNumber) ?? "0"
        return "\(value)s"
    }
}
