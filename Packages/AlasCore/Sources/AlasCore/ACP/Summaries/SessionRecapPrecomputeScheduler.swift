import Foundation

/// Decides when a hidden, idle session's recap is precomputed. Each session
/// waits until `lastSeenAt + threshold`, then joins a ready queue that one
/// worker drains serially, most recently seen first.
@MainActor
public final class SessionRecapPrecomputeScheduler {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private struct Waiting {
        let lastSeenAt: Date
        let token: UUID
        let timer: Task<Void, Never>
    }

    private let now: () -> Date
    private let sleep: Sleeper
    private let run: @MainActor (String) async -> Void

    private var waiting: [String: Waiting] = [:]
    private var ready: [String: Date] = [:]
    /// The session whose job is running, if any. Dropping it cancels the
    /// job's task; the next job still waits until `run` returns.
    public private(set) var runningSessionId: String?
    private var runningJob: Task<Void, Never>?
    /// A start is queued for a later main-actor turn.
    private var startQueued = false

    /// Low Power Mode; when true, due jobs wait.
    public var isSuspended = false {
        didSet { if !isSuspended { startNextIfIdle() } }
    }

    /// `run` returns when the job finished (any outcome). Jobs run one at a time.
    public init(
        now: @escaping () -> Date,
        sleep: @escaping Sleeper,
        run: @escaping @MainActor (String) async -> Void
    ) {
        self.now = now
        self.sleep = sleep
        self.run = run
    }

    /// Waiting and due entries, in due order: most recently seen first.
    public var pendingSessionIds: [String] {
        let all = waiting.mapValues(\.lastSeenAt).merging(ready) { $1 }
        return Self.dueOrder(all)
    }

    /// Session became unseen and idle at `lastSeenAt`; schedules at lastSeenAt + threshold.
    public func schedule(sessionId: String, lastSeenAt: Date, threshold: Duration) {
        drop(sessionId: sessionId)
        let delay = lastSeenAt.addingTimeInterval(Self.seconds(threshold)).timeIntervalSince(now())
        guard delay > 0 else {
            ready[sessionId] = lastSeenAt
            queueStart()
            return
        }
        let token = UUID()
        let sleep = sleep
        let timer = Task { [weak self] in
            do {
                try await sleep(.seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.becameDue(sessionId: sessionId, token: token)
        }
        waiting[sessionId] = Waiting(lastSeenAt: lastSeenAt, token: token, timer: timer)
    }

    /// Seen, busy, tab closed, or threshold → off.
    public func drop(sessionId: String) {
        waiting.removeValue(forKey: sessionId)?.timer.cancel()
        ready[sessionId] = nil
        if runningSessionId == sessionId { runningJob?.cancel() }
    }

    public func dropAll() {
        for entry in waiting.values { entry.timer.cancel() }
        waiting.removeAll()
        ready.removeAll()
        runningJob?.cancel()
    }

    private func becameDue(sessionId: String, token: UUID) {
        guard let entry = waiting[sessionId], entry.token == token else { return }
        waiting[sessionId] = nil
        ready[sessionId] = entry.lastSeenAt
        queueStart()
    }

    /// Starts on a later main-actor turn, so every entry made ready in this
    /// turn competes for the first slot, most recently seen first.
    private func queueStart() {
        guard !startQueued else { return }
        startQueued = true
        Task { [weak self] in
            guard let self else { return }
            self.startQueued = false
            self.startNextIfIdle()
        }
    }

    /// Picks the next job synchronously so the order reflects every entry
    /// due at this moment.
    private func startNextIfIdle() {
        guard runningSessionId == nil, !isSuspended,
              let next = Self.dueOrder(ready).first else { return }
        ready[next] = nil
        runningSessionId = next
        let run = run
        runningJob = Task { [weak self] in
            await run(next)
            guard let self else { return }
            self.runningSessionId = nil
            self.runningJob = nil
            self.startNextIfIdle()
        }
    }

    private static func dueOrder(_ entries: [String: Date]) -> [String] {
        entries.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }.map(\.key)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
