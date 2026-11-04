/// Counts the screens watching each simulator, so a stream starts with its
/// first screen and stops with its last.
public struct StreamSubscriptions: Sendable {
    public enum Change: Equatable, Sendable {
        case start, stop, none
    }

    private var counts: [String: Int] = [:]

    public init() {}

    public mutating func add(_ udid: String) -> Change {
        counts[udid, default: 0] += 1
        return counts[udid] == 1 ? .start : .none
    }

    public mutating func remove(_ udid: String) -> Change {
        guard let count = counts[udid] else { return .none }
        guard count > 1 else {
            counts[udid] = nil
            return .stop
        }
        counts[udid] = count - 1
        return .none
    }

    /// The watched devices, sorted.
    public var active: [String] { counts.keys.sorted() }
}
