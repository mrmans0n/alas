import Foundation

/// Binary-unit byte counts for checkpoint sizes and capture limits.
public enum CheckpointBytes: Sendable {
    public static func format(_ count: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB"]
        var value = Double(max(0, count))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let number = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return "\(number) \(units[unit])"
    }
}
