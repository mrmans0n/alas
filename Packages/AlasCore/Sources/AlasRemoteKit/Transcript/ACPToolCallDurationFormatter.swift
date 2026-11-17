import Foundation

public enum ACPToolCallDurationFormatter {
    public static func string(for duration: TimeInterval, locale: Locale = .current) -> String {
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
