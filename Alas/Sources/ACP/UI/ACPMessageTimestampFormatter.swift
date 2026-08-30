import Foundation

enum ACPMessageTimestampFormatter {
    static func string(
        for date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "d MMM, HH:mm"
        } else {
            formatter.dateFormat = "d MMM yyyy, HH:mm"
        }
        return formatter.string(from: date)
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
