import Foundation

/// Decides which pushes a change in session statuses calls for: one
/// attention push per entry into a waiting state, a clear when a session
/// leaves it, and a finished push when a turn ends. Statuses are
/// `RemoteSessionSummary.status` strings.
public struct RemotePushPlanner: Sendable {
    public struct Key: Hashable, Sendable {
        /// The `serverId` of the host the session runs on.
        public var originServerId: String
        /// The session's id on that host.
        public var sessionId: String

        public init(originServerId: String, sessionId: String) {
            self.originServerId = originServerId
            self.sessionId = sessionId
        }
    }

    public enum Action: Equatable, Sendable {
        case attention(Key, status: String)
        case clear(Key)
        /// A running or waiting session went idle.
        case finished(Key)
    }

    public static let waitingStatuses: Set<String> = ["awaitingPermission", "awaitingInput"]
    /// A session with no runner yet. One that goes from this straight to a
    /// wait is reattaching to a wait from before (a restart), so it pages nobody.
    public static let noRunnerStatus = "noRunner"
    public static let idleStatus = "idle"

    /// The waiting sessions, by the status last pushed.
    private var waiting: [Key: String]
    private var unattached: Set<Key>
    /// Sessions in a turn: streaming or waiting.
    private var running: Set<Key>

    /// Waits already present in `current` push nothing.
    public init(current: [Key: String]) {
        waiting = current.filter { Self.waitingStatuses.contains($0.value) }
        unattached = Set(current.filter { $0.value == Self.noRunnerStatus }.keys)
        running = Self.running(current)
    }

    /// Adopts the waits in `statuses` without pushing them, for sessions
    /// just learned about, such as a peer's on its first list.
    public mutating func baseline(_ statuses: [Key: String]) {
        waiting.merge(statuses.filter { Self.waitingStatuses.contains($0.value) }) { _, new in new }
        running.formUnion(Self.running(statuses))
    }

    /// The pushes moving to `statuses` calls for. A key missing from it is
    /// not waiting.
    public mutating func update(_ statuses: [Key: String]) -> [Action] {
        let next = statuses.filter { Self.waitingStatuses.contains($0.value) }
        var actions: [Action] = []
        for (key, status) in next where waiting[key] != status && !unattached.contains(key) {
            actions.append(.attention(key, status: status))
        }
        for key in waiting.keys where next[key] == nil {
            actions.append(.clear(key))
        }
        // Only a session still listed and idle finished; one that vanished was closed or removed.
        for key in running where statuses[key] == Self.idleStatus {
            actions.append(.finished(key))
        }
        running = Self.running(statuses)
        waiting = next
        unattached = Set(statuses.filter { $0.value == Self.noRunnerStatus }.keys)
        return actions
    }

    private static func running(_ statuses: [Key: String]) -> Set<Key> {
        Set(statuses.filter { $0.value == "streaming" || waitingStatuses.contains($0.value) }.keys)
    }

    /// The status last pushed for `key`, while it waits.
    public func status(of key: Key) -> String? { waiting[key] }
}
