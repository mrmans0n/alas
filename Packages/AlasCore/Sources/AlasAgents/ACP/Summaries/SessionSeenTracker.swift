import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Tracks whether the user can currently see each session: a session is seen
/// while its tab is visible and the app is active. It reports transitions and
/// remembers when each session was last seen in this process.
@MainActor
public final class SessionSeenTracker {
    public enum Event: Equatable, Sendable {
        /// Session became seen; `awayFrom` is the persisted/previous last-seen instant (nil if never).
        case becameSeen(sessionId: String, awayFrom: Date?)
        case becameUnseen(sessionId: String, at: Date)
    }

    /// The single external subscriber, owned by the app layer.
    public var onEvent: ((Event) -> Void)?
    /// The owning session manager's own reaction (persisting the last-seen
    /// stamp). Runs before `onEvent` and keeps `onEvent` free for the app.
    var ownerObserver: ((Event) -> Void)?

    private let now: () -> Date
    private var appActive: Bool
    private var visible: Set<String> = []
    private var lastSeen: [String: Date] = [:]

    public init(now: @escaping () -> Date, appActive: Bool) {
        self.now = now
        self.appActive = appActive
    }

    public func setVisible(_ visible: Bool, sessionId: String) {
        let wasSeen = isSeen(sessionId)
        if visible {
            self.visible.insert(sessionId)
        } else {
            self.visible.remove(sessionId)
        }
        transition(sessionId, wasSeen: wasSeen)
    }

    public func setAppActive(_ active: Bool) {
        guard active != appActive else { return }
        let affected = visible.sorted()
        let wasSeen = Dictionary(uniqueKeysWithValues: affected.map { ($0, isSeen($0)) })
        appActive = active
        for id in affected {
            transition(id, wasSeen: wasSeen[id] ?? false)
        }
    }

    public func isSeen(_ sessionId: String) -> Bool {
        appActive && visible.contains(sessionId)
    }

    private func transition(_ sessionId: String, wasSeen: Bool) {
        let seen = isSeen(sessionId)
        guard seen != wasSeen else { return }
        let event: Event
        if seen {
            event = .becameSeen(sessionId: sessionId, awayFrom: lastSeen[sessionId])
        } else {
            let at = now()
            lastSeen[sessionId] = at
            event = .becameUnseen(sessionId: sessionId, at: at)
        }
        ownerObserver?(event)
        onEvent?(event)
    }
}
