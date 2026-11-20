import AlasRemoteKit
import Foundation

/// Follows only runs this phone launched. The host owns their lifetime; the screen that launched
/// one may be gone by the time it finishes, and the link may come back on a new socket.
@MainActor
final class PhoneRunTracker {
    typealias OpenConsole = (PeerConsoleSummary) -> Void

    private weak var hub: HostHub?
    private let hostID: UUID
    private let storageKey: String
    private var pending: Set<String>
    private var openers: [String: OpenConsole] = [:]
    private var snapshotID: Int?
    private var subscribed = false
    private var consoleQueries: [String: (deadline: ContinuousClock.Instant, open: OpenConsole)] = [:]
    private var consoleTask: Task<Void, Never>?

    init(hub: HostHub, hostID: UUID) {
        self.hub = hub
        self.hostID = hostID
        storageKey = "pendingRuns.\(hostID.uuidString)"
        pending = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    func follow(_ runID: String, openConsole: @escaping OpenConsole) {
        pending.insert(runID)
        if hub?.supports(PeerConsoleCapability.phoneV1, on: hostID) == true {
            openers[runID] = openConsole
        }
        save()
        AppDelegate.prepareRunNotifications()
        refresh()
    }

    func refresh() {
        guard !pending.isEmpty, let hub, hub.state(of: hostID) == .online else { return }
        let id = hub.nextHostRequestId()
        snapshotID = id
        hub.send(.host(RemoteRunFeed.snapshot(id: id)), to: hostID)
    }

    func disconnect() {
        snapshotID = nil
        subscribed = false
        openers.removeAll()
        consoleQueries.removeAll()
        consoleTask?.cancel()
        consoleTask = nil
    }

    func forget() {
        disconnect()
        pending.removeAll()
        save()
    }

    func receive(_ message: PhoneServerMessage) {
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
                if !pending.isEmpty, let hub {
                    hub.send(.host(RemoteRunFeed.subscribe(id: hub.nextHostRequestId(), after: cursor)), to: hostID)
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
            if let exitCode { AppDelegate.postRunResult(hostID: hostID, runID: run.id, name: run.name, exitCode: exitCode) }
            finish(CollectionOfOne(run.id))
        }
    }

    private func finish(_ ids: some Sequence<String>) {
        let count = pending.count
        pending.subtract(ids)
        guard pending.count != count else { return }
        openers = openers.filter { pending.contains($0.key) }
        save()
        if pending.isEmpty, subscribed, let hub {
            hub.send(.host(RemoteRunFeed.unsubscribe(id: hub.nextHostRequestId())), to: hostID)
            subscribed = false
        }
    }

    private func save() {
        UserDefaults.standard.set(pending.isEmpty ? nil : Array(pending), forKey: storageKey)
    }

    private func findConsole(_ id: String, open: @escaping OpenConsole) {
        consoleQueries[id] = (.now + .seconds(3), open)
        guard consoleTask == nil else { return }
        // The run record can precede the console's zmx socket or its first grid size.
        consoleTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let now = ContinuousClock.now
                consoleQueries = consoleQueries.filter { now < $0.value.deadline }
                guard !consoleQueries.isEmpty else { consoleTask = nil; return }
                hub?.send(.console(.list), to: hostID)
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
        }
    }
}
