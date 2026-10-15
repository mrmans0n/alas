import Foundation
import Observation

/// A position in the host's change log. Events after a cursor describe every
/// change since the snapshot that returned it.
public struct HostCursor: Hashable, Comparable, Sendable {
    public let sequence: UInt64

    public static func < (lhs: HostCursor, rhs: HostCursor) -> Bool {
        lhs.sequence < rhs.sequence
    }
}

/// One change to what the host holds. Each keyed kind has a removal event.
public enum HostEvent: Equatable, Sendable {
    case projectChanged(ProjectConfig)
    case projectRemoved(id: String)
    case worktreeChanged(WorktreeSnapshot)
    case worktreeRemoved(projectID: String, worktreeID: String)
    case workspaceCheckoutChanged(WorkspaceCheckout)
    case workspaceCheckoutRemoved(id: UUID)
    case runChanged(RunRecord)
    case runRemoved(id: String)
    /// Changes were missed: read a new snapshot and subscribe after its cursor.
    case resync

    var key: HostEventKey {
        switch self {
        case .projectChanged(let project): .project(project.id)
        case .projectRemoved(let id): .project(id)
        case .worktreeChanged(let snapshot): .worktree(projectID: snapshot.worktree.projectId, worktreeID: snapshot.worktree.id)
        case .worktreeRemoved(let projectID, let worktreeID): .worktree(projectID: projectID, worktreeID: worktreeID)
        case .workspaceCheckoutChanged(let checkout): .workspaceCheckout(checkout.id)
        case .workspaceCheckoutRemoved(let id): .workspaceCheckout(id)
        case .runChanged(let record): .run(record.id)
        case .runRemoved(let id): .run(id)
        case .resync: .resync
        }
    }
}

/// What an event is about; a later event with the same key supersedes it.
enum HostEventKey: Hashable {
    case project(String)
    case worktree(projectID: String, worktreeID: String)
    case workspaceCheckout(UUID)
    case run(String)
    case resync
}

/// One subscriber's view of the change log. Events not yet read coalesce
/// per key, so a slow reader gets each thing's latest state; past
/// `pendingLimit` distinct keys it gets a single `.resync` instead.
@MainActor
public final class HostSubscription {
    private var pendingKeys: [HostEventKey] = []
    private var pending: [HostEventKey: HostEvent] = [:]
    private var waiter: CheckedContinuation<[HostEvent]?, Never>?
    private var isCancelled = false
    private let pendingLimit: Int
    private let onCancel: (HostSubscription) -> Void

    init(pendingLimit: Int, onCancel: @escaping (HostSubscription) -> Void) {
        self.pendingLimit = pendingLimit
        self.onCancel = onCancel
    }

    /// The events since the last call, coalesced, waiting for one if none
    /// are pending. Nil once cancelled.
    public func next() async -> [HostEvent]? {
        if isCancelled { return nil }
        if !pendingKeys.isEmpty { return drain() }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// Stops the subscription; a pending `next()` returns nil.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        pending.removeAll()
        pendingKeys.removeAll()
        waiter?.resume(returning: nil)
        waiter = nil
        onCancel(self)
    }

    func receive(_ events: [HostEvent]) {
        guard !isCancelled, !events.isEmpty else { return }
        if pending[.resync] == nil {
            for event in events {
                let key = event.key
                if pending.updateValue(event, forKey: key) == nil {
                    pendingKeys.append(key)
                }
            }
            if pendingKeys.count > pendingLimit {
                pendingKeys = [.resync]
                pending = [.resync: .resync]
            }
        }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: drain())
        }
    }

    private func drain() -> [HostEvent] {
        defer {
            pendingKeys.removeAll()
            pending.removeAll()
        }
        return pendingKeys.compactMap { pending[$0] }
    }
}

/// The host's change log: events numbered by cursor, a bounded tail of them
/// kept for subscribers catching up, and the live subscriptions.
@MainActor
final class HostEventLog {
    private(set) var cursor = HostCursor(sequence: 0)
    private var retained: [(cursor: HostCursor, event: HostEvent)] = []
    private var subscriptions: [ObjectIdentifier: HostSubscription] = [:]
    private let retention: Int
    private let pendingLimit: Int

    init(retention: Int = 1024, pendingLimit: Int = 512) {
        self.retention = retention
        self.pendingLimit = pendingLimit
    }

    func publish(_ events: [HostEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            cursor = HostCursor(sequence: cursor.sequence + 1)
            retained.append((cursor, event))
        }
        if retained.count > retention {
            retained.removeFirst(retained.count - retention)
        }
        for subscription in subscriptions.values {
            subscription.receive(events)
        }
    }

    /// A subscription delivering the events after `after`: those still
    /// retained first, or `.resync` when some have been dropped.
    func subscribe(after: HostCursor) -> HostSubscription {
        let subscription = HostSubscription(pendingLimit: pendingLimit) { [weak self] in
            self?.subscriptions.removeValue(forKey: ObjectIdentifier($0))
        }
        subscriptions[ObjectIdentifier(subscription)] = subscription
        if after < cursor {
            let oldest = retained.first?.cursor.sequence ?? cursor.sequence + 1
            if after.sequence + 1 < oldest {
                subscription.receive([.resync])
            } else {
                subscription.receive(retained.filter { $0.cursor > after }.map(\.event))
            }
        }
        return subscription
    }
}

/// Turns the core's state into the host's events: it watches the projects,
/// their worktrees and claims, and the run records, and the Workspace store
/// for writes, and publishes what changed since it last looked.
@MainActor
final class HostEventSource {
    let log = HostEventLog()
    private let core: AlasCoreContext
    private var projects: [String: ProjectConfig] = [:]
    private var worktrees: [HostEventKey: WorktreeSnapshot] = [:]
    private var runs: [String: RunRecord] = [:]
    /// Nil until the first load, which is the baseline rather than a change.
    private var checkouts: [UUID: WorkspaceCheckout]?
    private var refreshScheduled = false

    init(core: AlasCoreContext) {
        self.core = core
        // The baseline: what exists now is not a change.
        projects = Self.byID(ProjectsAPI(core: core).list())
        worktrees = Self.keyed(WorktreesAPI(core: core).list(includingArchived: true))
        runs = Self.byID(RunsAPI(core: core).list())
        observeInMemoryState()
        let store = core.workspaceStore
        Task { [weak self] in
            for await _ in await store.changes() {
                guard let self else { return }
                if let checkouts = try? await WorkspacesAPI(core: self.core).list() {
                    publishCheckouts(checkouts)
                }
            }
        }
    }

    /// Publishes what changed in projects, worktrees and runs since the last look.
    func refreshInMemoryState() {
        refreshScheduled = false
        var events: [HostEvent] = []
        let currentProjects = Self.byID(ProjectsAPI(core: core).list())
        events += Self.diff(old: projects, new: currentProjects, changed: HostEvent.projectChanged, removed: { .projectRemoved(id: $0) })
        projects = currentProjects

        let currentWorktrees = Self.keyed(WorktreesAPI(core: core).list(includingArchived: true))
        events += Self.diff(old: worktrees, new: currentWorktrees, changed: HostEvent.worktreeChanged) { key in
            guard case let .worktree(projectID, worktreeID) = key else { return .resync }
            return .worktreeRemoved(projectID: projectID, worktreeID: worktreeID)
        }
        worktrees = currentWorktrees

        let currentRuns = Self.byID(RunsAPI(core: core).list())
        events += Self.diff(old: runs, new: currentRuns, changed: HostEvent.runChanged, removed: { .runRemoved(id: $0) })
        runs = currentRuns
        log.publish(events)
    }

    /// Publishes what changed among the Workspace checkouts.
    func publishCheckouts(_ list: [WorkspaceCheckout]) {
        let current = Self.byID(list)
        if let checkouts {
            log.publish(Self.diff(old: checkouts, new: current, changed: HostEvent.workspaceCheckoutChanged, removed: { .workspaceCheckoutRemoved(id: $0) }))
        }
        checkouts = current
    }

    private func observeInMemoryState() {
        let core = core
        withObservationTracking {
            _ = core.projects.projects
            _ = core.projects.worktreesByProject
            _ = core.projects.worktreeOperationStates
            _ = core.runRecords
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
    }

    /// Several changes in one turn become one refresh.
    private func scheduleRefresh() {
        observeInMemoryState()
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self, refreshScheduled else { return }
            refreshInMemoryState()
        }
    }

    private static func byID<Value: Identifiable>(_ values: [Value]) -> [Value.ID: Value] {
        Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    private static func keyed(_ snapshots: [WorktreeSnapshot]) -> [HostEventKey: WorktreeSnapshot] {
        Dictionary(
            snapshots.map { (HostEventKey.worktree(projectID: $0.worktree.projectId, worktreeID: $0.worktree.id), $0) },
            uniquingKeysWith: { _, last in last }
        )
    }

    private static func diff<Key: Hashable, Value: Equatable>(
        old: [Key: Value],
        new: [Key: Value],
        changed: (Value) -> HostEvent,
        removed: (Key) -> HostEvent
    ) -> [HostEvent] {
        var events: [HostEvent] = []
        for (key, value) in new where old[key] != value {
            events.append(changed(value))
        }
        for key in old.keys where new[key] == nil {
            events.append(removed(key))
        }
        return events
    }
}
