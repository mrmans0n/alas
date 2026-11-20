import Foundation

/// Follows only runs this phone launched. The host owns their lifetime; the screen that launched
/// one may be gone by the time it finishes, and the link may come back on a new socket.
@MainActor
public final class PhoneRunTracker {
    public typealias OpenConsole = @MainActor (PeerConsoleSummary) -> Void
    public typealias ClientMessage = RemoteClientMessageOf<OpaqueHostMessage, OpaqueHostMessage>
    public typealias ServerMessage = RemoteServerMessageOf<OpaqueHostMessage, OpaqueHostMessage>

    private let nextRequestID: @MainActor () -> Int?
    private let send: @MainActor (ClientMessage) -> Void
    private let save: @MainActor (Set<String>) -> Void
    private let notify: @MainActor (String, String, Int32) -> Void
    private var pending: Set<String>
    private var openers: [String: OpenConsole] = [:]
    private var snapshotID: Int?
    private var subscribed = false
    private var consoleQueries: [String: (deadline: ContinuousClock.Instant, open: OpenConsole)] = [:]
    private var consoleTask: Task<Void, Never>?

    /// `nextRequestID` returns nil while offline; `save` persists pending IDs for the next connection.
    public init(
        pending: Set<String>,
        nextRequestID: @escaping @MainActor () -> Int?,
        send: @escaping @MainActor (ClientMessage) -> Void,
        save: @escaping @MainActor (Set<String>) -> Void,
        notify: @escaping @MainActor (_ runID: String, _ name: String, _ exitCode: Int32) -> Void
    ) {
        self.pending = pending
        self.nextRequestID = nextRequestID
        self.send = send
        self.save = save
        self.notify = notify
    }

    public func follow(_ runID: String, openConsole: OpenConsole? = nil) {
        pending.insert(runID)
        openers[runID] = openConsole
        save(pending)
        refresh()
    }

    public func refresh() {
        guard !pending.isEmpty, let id = nextRequestID() else { return }
        snapshotID = id
        send(.host(RemoteRunFeed.snapshot(id: id)))
    }

    public func disconnect() {
        snapshotID = nil
        subscribed = false
        openers.removeAll()
        consoleQueries.removeAll()
        consoleTask?.cancel()
        consoleTask = nil
    }

    public func forget() {
        disconnect()
        pending.removeAll()
        save(pending)
    }

    public func receive(_ message: ServerMessage) {
        switch message {
        case .host(let raw) where !pending.isEmpty:
            switch RemoteRunFeed.update(in: raw) {
            case .snapshot(let id, let cursor, let runs) where id == snapshotID:
                snapshotID = nil
                // The latest requested snapshot was taken after these run IDs were accepted.
                // An absent record was rolled back or superseded; it tells us no exit status.
                let missing = pending.subtracting(runs.lazy.map(\.id))
                for run in runs { observe(run) }
                finish(missing)
                if !pending.isEmpty, let id = nextRequestID() {
                    send(.host(RemoteRunFeed.subscribe(id: id, after: cursor)))
                    subscribed = true
                }
            case .events(let changed, let removed, let resync) where subscribed:
                if resync {
                    refresh()
                } else {
                    for run in changed { observe(run) }
                    finish(removed)
                }
            default:
                break
            }
        case .console(.list(let consoles)) where !consoleQueries.isEmpty:
            for console in consoles {
                if let query = consoleQueries.removeValue(forKey: console.consoleId), .now < query.deadline {
                    query.open(console)
                }
            }
        default:
            break
        }
    }

    private func observe(_ run: RemoteRunRecord) {
        guard pending.contains(run.id), run.status != .starting else { return }
        if let open = openers.removeValue(forKey: run.id), let consoleID = run.visibleConsoleID {
            findConsole(consoleID, open: open)
        }
        if case .finished(let exitCode) = run.status {
            if let exitCode { notify(run.id, run.name, exitCode) }
            finish(CollectionOfOne(run.id))
        }
    }

    private func finish(_ ids: some Sequence<String>) {
        let count = pending.count
        pending.subtract(ids)
        guard pending.count != count else { return }
        openers = openers.filter { pending.contains($0.key) }
        save(pending)
        if pending.isEmpty, subscribed {
            subscribed = false
            if let id = nextRequestID() { send(.host(RemoteRunFeed.unsubscribe(id: id))) }
        }
    }

    private func findConsole(_ id: String, open: @escaping OpenConsole) {
        consoleQueries[id] = (.now + .seconds(3), open)
        guard consoleTask == nil else { return }
        // The run record can precede the console's zmx socket or its first grid size.
        consoleTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let now = ContinuousClock.now
                consoleQueries = consoleQueries.filter { now < $0.value.deadline }
                guard !consoleQueries.isEmpty else {
                    consoleTask = nil
                    return
                }
                send(.console(.list))
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
        }
    }
}
