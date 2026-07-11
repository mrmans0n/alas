import Foundation

private enum RelativeTimeFormatters {
    static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

/// Compact "now / Nm / Nh / Nd / MMM d" age label, used in commit rows
/// and commit headers.
func relativeTime(_ date: Date) -> String {
    let delta = Date().timeIntervalSince(date)
    if delta < 60 { return "now" }
    if delta < 3600 { return "\(Int(delta / 60))m" }
    if delta < 86_400 { return "\(Int(delta / 3600))h" }
    if delta < 30 * 86_400 { return "\(Int(delta / 86_400))d" }
    return RelativeTimeFormatters.monthDay.string(from: date)
}
