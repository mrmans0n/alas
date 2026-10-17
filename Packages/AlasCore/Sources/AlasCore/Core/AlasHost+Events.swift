import Foundation
import Observation

/// A position in the host's change log. Events after a cursor describe every
/// change since the snapshot that returned it. Each log has its own
/// generation, so a cursor from before the host restarted is never taken for
/// one of the current log's.
public struct HostCursor: Hashable, Codable, Sendable {
    public let generation: UUID
    public let sequence: UInt64

    public init(generation: UUID, sequence: UInt64) {
        self.generation = generation
        self.sequence = sequence
    }
}

/// One change to what the host holds. Each keyed kind has a removal event.
public enum HostEvent: Codable, Equatable, Sendable {
    case projectChanged(ProjectSnapshot)
    case projectRemoved(id: String)
    case worktreeChanged(WorktreeSnapshot)
    case worktreeRemoved(projectID: String, worktreeID: String)
    case workspaceCheckoutChanged(WorkspaceCheckoutSnapshot)
    case workspaceCheckoutRemoved(id: UUID)
    case runChanged(RunRecord)
    case runRemoved(id: String)
    case sessionChanged(HostSessionSummary)
    case sessionRemoved(owner: SessionOwnerID, id: String)
    /// What changed in a followed session's transcript.
    case transcript(owner: SessionOwnerID, id: String, delta: HostTranscriptDelta)
    /// A followed session's agent waits on `request`.
    case pendingRequest(owner: SessionOwnerID, id: String, request: HostPendingRequest)
    /// A followed session's request was answered or withdrawn.
    case pendingRequestResolved(owner: SessionOwnerID, id: String, requestID: HostPendingRequestID)
    /// A followed session's state besides its transcript changed.
    case sessionState(owner: SessionOwnerID, id: String, state: HostSessionState)
    /// Changes were missed: read a new snapshot and subscribe after its cursor.
    case resync

    // The wire names each payload.
    private enum ProjectChangedCodingKeys: String, CodingKey { case _0 = "project" }
    private enum WorktreeChangedCodingKeys: String, CodingKey { case _0 = "worktree" }
    private enum WorkspaceCheckoutChangedCodingKeys: String, CodingKey { case _0 = "checkout" }
    private enum RunChangedCodingKeys: String, CodingKey { case _0 = "run" }
    private enum SessionChangedCodingKeys: String, CodingKey { case _0 = "session" }

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
        case .sessionChanged(let summary): .session(owner: summary.owner, id: summary.id)
        case .sessionRemoved(let owner, let id): .session(owner: owner, id: id)
        case .transcript(let owner, let id, _): .transcript(owner: owner, id: id)
        case .pendingRequest(let owner, let id, let request): .pendingRequest(owner: owner, id: id, request.id)
        case .pendingRequestResolved(let owner, let id, let requestID): .pendingRequest(owner: owner, id: id, requestID)
        case .sessionState(let owner, let id, _): .sessionState(owner: owner, id: id)
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
    case session(owner: SessionOwnerID, id: String)
    case transcript(owner: SessionOwnerID, id: String)
    case pendingRequest(owner: SessionOwnerID, id: String, HostPendingRequestID)
    case sessionState(owner: SessionOwnerID, id: String)
    case resync
}

/// One subscriber's view of the change log. Events not yet read coalesce
/// per key, so a slow reader gets each thing's latest state; past
/// `pendingLimit` distinct keys it gets a single `.resync` instead.
///
/// Transcript and pending-request events come only for the sessions it
/// follows. They are worked out when read, from each transcript's change
/// log, so a slow reader gets one delta per session rather than a backlog.
@MainActor
public final class HostSubscription {
    private var pendingKeys: [HostEventKey] = []
    private var pending: [HostEventKey: HostEvent] = [:]
    private var waiter: CheckedContinuation<Void, Never>?
    private var isCancelled = false
    private let pendingLimit: Int
    private let onCancel: (HostSubscription) -> Void
    private let liveSession: (String) -> (SessionOwnerID, ACPSession, ACPSessionManager)?
    private var followed: [String: FollowedSession] = [:]
    private var wakeScheduled = false
    /// The log position the pending events reach.
    private var pendingThrough: HostCursor
    /// The log position the events `next()` last returned reach: a client
    /// that read them resumes after it.
    public private(set) var cursor: HostCursor

    init(
        after cursor: HostCursor,
        pendingLimit: Int,
        liveSession: @escaping (String) -> (SessionOwnerID, ACPSession, ACPSessionManager)? = { _ in nil },
        onCancel: @escaping (HostSubscription) -> Void
    ) {
        self.cursor = cursor
        pendingThrough = cursor
        self.pendingLimit = pendingLimit
        self.liveSession = liveSession
        self.onCancel = onCancel
    }

    /// The events since the last call, coalesced, waiting for one if none
    /// are pending. Nil once cancelled. A subscription has one reader:
    /// calling this while another call is waiting is a programming error.
    public func next() async -> [HostEvent]? {
        while !isCancelled {
            let events = drain()
            if !events.isEmpty { return events }
            precondition(waiter == nil, "HostSubscription.next() has one reader at a time")
            await withCheckedContinuation { waiter = $0 }
        }
        return nil
    }

    /// Streams the loaded session `sessionID`'s transcript and pending
    /// requests. The first delta continues from `revision` when the
    /// transcript can still be served from it, and otherwise resets to its
    /// newest messages. Following again starts over from `revision`.
    public func follow(_ sessionID: String, from revision: TranscriptRevision? = nil) throws {
        guard !isCancelled else { return }
        guard let (owner, session, manager) = liveSession(sessionID) else { throw SessionRefusal.notFound }
        // Retained before the old follow lets go, so the log keeps its epoch.
        let previous = followed[sessionID]
        followed[sessionID] = FollowedSession(owner: owner, session: session, manager: manager, from: revision) { [weak self] in
            self?.scheduleWake()
        }
        previous?.release()
        scheduleWake()
    }

    /// Stops streaming `sessionID`'s transcript and pending requests.
    public func unfollow(_ sessionID: String) {
        followed.removeValue(forKey: sessionID)?.release()
    }

    /// Stops the subscription and releases every followed session; a
    /// pending `next()` returns nil.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        pending.removeAll()
        pendingKeys.removeAll()
        followed.values.forEach { $0.release() }
        followed.removeAll()
        wake()
        onCancel(self)
    }

    isolated deinit {
        followed.values.forEach { $0.release() }
    }

    /// Transcript signals fire before the change is stored, so the reader
    /// wakes on the next turn, when it can read it.
    private func scheduleWake() {
        guard !wakeScheduled else { return }
        wakeScheduled = true
        Task { @MainActor [weak self] in
            self?.wakeScheduled = false
            self?.wake()
        }
    }

    private func wake() {
        let waiter = waiter
        self.waiter = nil
        waiter?.resume()
    }

    func receive(_ events: [HostEvent], through position: HostCursor) {
        guard !isCancelled, !events.isEmpty else { return }
        pendingThrough = position
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
        wake()
    }

    private func drain() -> [HostEvent] {
        cursor = pendingThrough
        var events = pendingKeys.compactMap { pending[$0] }
        pendingKeys.removeAll()
        pending.removeAll()
        for session in followed.values where session.isDirty {
            events += session.events()
        }
        return events
    }
}

/// The host's change log: events numbered by cursor, a bounded tail of them
/// kept for subscribers catching up, and the live subscriptions.
@MainActor
final class HostEventLog {
    private(set) var cursor = HostCursor(generation: UUID(), sequence: 0)
    private var retained: [(cursor: HostCursor, event: HostEvent)] = []
    /// Held weakly: a subscription its owner drops goes away with it.
    private var subscriptions: [ObjectIdentifier: WeakSubscription] = [:]
    private let retention: Int
    private let pendingLimit: Int
    /// Finds a loaded session for subscriptions to follow.
    var liveSession: (String) -> (SessionOwnerID, ACPSession, ACPSessionManager)? = { _ in nil }

    init(retention: Int = 1024, pendingLimit: Int = 512) {
        self.retention = retention
        self.pendingLimit = pendingLimit
    }

    func publish(_ events: [HostEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            cursor = HostCursor(generation: cursor.generation, sequence: cursor.sequence + 1)
            retained.append((cursor, event))
        }
        if retained.count > retention {
            retained.removeFirst(retained.count - retention)
        }
        subscriptions = subscriptions.filter { $0.value.subscription != nil }
        for entry in subscriptions.values {
            entry.subscription?.receive(events, through: cursor)
        }
    }

    /// A subscription delivering the events after `after`: those still
    /// retained first, or `.resync` when some have been dropped or the
    /// cursor is not one of this log's.
    func subscribe(after: HostCursor) -> HostSubscription {
        let subscription = HostSubscription(after: after, pendingLimit: pendingLimit, liveSession: liveSession) { [weak self] in
            self?.subscriptions.removeValue(forKey: ObjectIdentifier($0))
        }
        subscriptions[ObjectIdentifier(subscription)] = WeakSubscription(subscription: subscription)
        if after.generation != cursor.generation || after.sequence > cursor.sequence {
            subscription.receive([.resync], through: cursor)
        } else if after.sequence < cursor.sequence {
            let oldest = retained.first?.cursor.sequence ?? cursor.sequence + 1
            if after.sequence + 1 < oldest {
                subscription.receive([.resync], through: cursor)
            } else {
                subscription.receive(retained.filter { $0.cursor.sequence > after.sequence }.map(\.event), through: cursor)
            }
        }
        return subscription
    }
}

private struct WeakSubscription {
    weak var subscription: HostSubscription?
}

/// Turns the core's state into the host's events: it watches the projects,
/// their worktrees and claims, and the run records, and the Workspace store
/// for writes, and publishes what changed since it last looked.
@MainActor
final class HostEventSource {
    let log = HostEventLog()
    private let core: AlasCoreContext
    private var projects: [String: ProjectSnapshot] = [:]
    private var worktrees: [HostEventKey: WorktreeSnapshot] = [:]
    private var runs: [String: RunRecord] = [:]
    private var sessions: [HostEventKey: HostSessionSummary] = [:]
    /// Session managers and live transcripts announce changes through
    /// signals rather than Observation; renewed on every refresh.
    private var sessionSignals: Set<ChangeSubscription> = []
    /// Nil until the first load, which is the baseline rather than a change.
    private var checkouts: [UUID: WorkspaceCheckoutSnapshot]?
    private var checkoutList: [WorkspaceCheckoutSnapshot] = []
    private var checkoutLoads = 0
    /// The store's change stream, registered before any load reads the
    /// store, so no write can land between a load and the first event.
    private var checkoutChanges: Task<AsyncStream<Void>, Never>?
    private var publishedCheckoutLoad = 0
    private var refreshScheduled = false

    init(core: AlasCoreContext) {
        self.core = core
        // The baseline: what exists now is not a change.
        projects = Self.byID(ProjectsAPI(core: core).list())
        worktrees = Self.keyed(WorktreesAPI(core: core).list(includingArchived: true))
        runs = Self.byID(RunsAPI(core: core).list())
        sessions = Self.keyed(SessionsAPI(core: core).list())
        log.liveSession = { [weak core] id in
            guard let core else { return nil }
            for (owner, manager) in core.sessionManagers {
                if let session = manager.liveSession(for: id) { return (owner, session, manager) }
            }
            return nil
        }
        observeInMemoryState()
        renewSessionSignals()
        let store = core.workspaceStore
        let changes = Task { await store.changes() }
        checkoutChanges = changes
        Task { [weak self] in
            for await _ in await changes.value {
                guard let self else { return }
                _ = try? await loadCheckouts()
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

        let currentSessions = Self.keyed(SessionsAPI(core: core).list())
        events += Self.diff(old: sessions, new: currentSessions, changed: HostEvent.sessionChanged) { key in
            guard case let .session(owner, id) = key else { return .resync }
            return .sessionRemoved(owner: owner, id: id)
        }
        sessions = currentSessions
        renewSessionSignals()
        log.publish(events)
    }

    /// Loads the Workspace checkouts and publishes what changed among them,
    /// returning the latest published list. A load that finishes after a
    /// later one is dropped, so it can never put back an older state.
    func loadCheckouts() async throws -> [WorkspaceCheckoutSnapshot] {
        _ = await checkoutChanges?.value
        checkoutLoads += 1
        let load = checkoutLoads
        let list = try await WorkspacesAPI(core: core).list()
        if load > publishedCheckoutLoad {
            publishedCheckoutLoad = load
            let current = Self.byID(list)
            if let checkouts {
                log.publish(Self.diff(old: checkouts, new: current, changed: HostEvent.workspaceCheckoutChanged, removed: { .workspaceCheckoutRemoved(id: $0) }))
            }
            checkouts = current
            checkoutList = list
        }
        return checkoutList
    }

    private func observeInMemoryState() {
        let core = core
        withObservationTracking {
            _ = core.projects.projects
            _ = core.projects.worktreesByProject
            _ = core.projects.worktreeOperationStates
            _ = core.runRecords
            _ = core.sessionManagers
            _ = core.delegatedSessionParents
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeInMemoryState()
                self?.scheduleRefresh()
            }
        }
    }

    /// Follows the current session managers and live transcripts. Signals
    /// fire before the change is stored; the refresh they schedule runs after.
    private func renewSessionSignals() {
        sessionSignals.removeAll()
        let changed: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        for manager in core.sessionManagers.values {
            manager.willChange.observe(changed).store(in: &sessionSignals)
            manager.summaryWillChange.observe(changed).store(in: &sessionSignals)
            for runner in manager.runners.values {
                runner.session.transcript.$streamingState.signal.observe { _ in changed() }.store(in: &sessionSignals)
            }
        }
    }

    /// Several changes in one turn become one refresh.
    private func scheduleRefresh() {
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

    private static func keyed(_ summaries: [HostSessionSummary]) -> [HostEventKey: HostSessionSummary] {
        Dictionary(
            summaries.map { (HostEventKey.session(owner: $0.owner, id: $0.id), $0) },
            uniquingKeysWith: { _, last in last }
        )
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
