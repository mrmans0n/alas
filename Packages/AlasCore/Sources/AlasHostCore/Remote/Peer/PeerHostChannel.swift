import Foundation
import AlasModel
import AlasFeatures
import AlasIntegrations

/// The host protocol, spoken to one paired peer: requests matched to their
/// answers by id, and the peer's state kept current from a snapshot and the
/// subscription after its cursor. The transport delivers what the peer sends
/// through `receive(_:)`; nothing is retried on its own.
@MainActor
public final class PeerHostChannel {
    public static let defaultTimeout: Duration = .seconds(60)
    public nonisolated static let unansweredMessage = "The peer did not answer."

    /// The peer's projects, worktrees, Workspace checkouts and runs.
    public struct State: Equatable, Sendable {
        public var projects: [ProjectSnapshot]
        /// Archived ones included.
        public var worktrees: [WorktreeSnapshot]
        public var workspaceCheckouts: [WorkspaceCheckoutSnapshot]
        public var runs: [RunRecord]
        /// Shepherd pills by session id; sessions without one are absent.
        public var shepherds: [String: HostSessionShepherd]
        /// Review statuses by worktree id, as the followed ones change.
        public var reviewStatuses: [String: ReviewLoopSnapshot] = [:]
        /// Counts each `reviewsChanged` per worktree, for a view to refetch on; dropped with the worktree.
        public var reviewRevisions: [String: Int] = [:]

        public init(_ snapshot: HostSnapshot) {
            projects = snapshot.projects
            worktrees = snapshot.worktrees
            workspaceCheckouts = snapshot.workspaceCheckouts
            runs = snapshot.runs
            shepherds = Dictionary(snapshot.sessions.compactMap { s in s.shepherd.map { (s.id, $0) } }) { _, last in last }
        }

        /// Upserts or removes by key; transcript and request events are ignored.
        public mutating func apply(_ event: HostEvent) {
            switch event {
            case .projectChanged(let project):
                Self.upsert(project, in: &projects)
            case .projectRemoved(let id):
                projects.removeAll { $0.id == id }
                for snapshot in worktrees where snapshot.worktree.projectId == id {
                    reviewStatuses[snapshot.worktree.id] = nil
                    reviewRevisions[snapshot.worktree.id] = nil
                }
                worktrees.removeAll { $0.worktree.projectId == id }
            case .worktreeChanged(let snapshot):
                let key = (snapshot.worktree.projectId, snapshot.worktree.id)
                if let index = worktrees.firstIndex(where: { ($0.worktree.projectId, $0.worktree.id) == key }) {
                    worktrees[index] = snapshot
                } else {
                    worktrees.append(snapshot)
                }
            case .worktreeRemoved(let projectID, let worktreeID):
                worktrees.removeAll { $0.worktree.projectId == projectID && $0.worktree.id == worktreeID }
                reviewStatuses[worktreeID] = nil
                reviewRevisions[worktreeID] = nil
            case .workspaceCheckoutChanged(let checkout):
                Self.upsert(checkout, in: &workspaceCheckouts)
            case .workspaceCheckoutRemoved(let id):
                workspaceCheckouts.removeAll { $0.id == id }
            case .runChanged(let run):
                Self.upsert(run, in: &runs)
            case .runRemoved(let id):
                runs.removeAll { $0.id == id }
            case .sessionChanged(let summary):
                shepherds[summary.id] = summary.shepherd
            case .sessionRemoved(_, let id):
                shepherds[id] = nil
            case .reviewStatus(let worktreeID, let snapshot):
                reviewStatuses[worktreeID] = snapshot
            case .reviewsChanged(let worktreeID):
                reviewRevisions[worktreeID, default: 0] += 1
            case .transcript, .pendingRequest, .pendingRequestResolved,
                 .sessionState, .notice, .worktreeNotice, .resync:
                break
            }
        }

        private static func upsert<Element: Identifiable>(_ element: Element, in elements: inout [Element]) {
            if let index = elements.firstIndex(where: { $0.id == element.id }) {
                elements[index] = element
            } else {
                elements.append(element)
            }
        }
    }

    /// Nil until the first snapshot, and after `disconnect()`.
    public private(set) var state: State?
    /// Whether events are applied: from the subscription's `.subscribed`
    /// until a resync or a disconnect replaces it.
    public private(set) var isSubscribed = false
    public private(set) var isConnecting = false
    /// Called when `state` or `isSubscribed` changes.
    public var onChange: (@MainActor () -> Void)?
    /// Called with each notice the peer relays.
    public var onNotice: (@MainActor (HostNotice) -> Void)?
    /// Called with each worktree notice the peer relays.
    public var onWorktreeNotice: (@MainActor (HostWorktreeNotice) -> Void)?

    private let timeout: Duration
    private let send: @MainActor (HostClientMessage) -> Void
    private var nextID = 1
    private var pending: [Int: (continuation: CheckedContinuation<HostResponse, Never>, timeout: Task<Void, Never>)] = [:]
    /// Bumped by `disconnect()`, so a connect it interrupted publishes nothing.
    private var epoch = 0
    /// The current connect's subscribe request: its `.subscribed` starts
    /// applying events at once, since the host's first batch can follow it
    /// before `connect()` resumes.
    private var subscribeID: Int?

    public init(timeout: Duration = defaultTimeout, send: @escaping @MainActor (HostClientMessage) -> Void) {
        self.timeout = timeout
        self.send = send
    }

    /// Takes a snapshot, then subscribes after its cursor. Does nothing while
    /// a connect is under way.
    public func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        isSubscribed = false // drop batches of the subscription being replaced
        let epoch = self.epoch
        defer { if epoch == self.epoch { isConnecting = false } }
        guard case .snapshot(let snapshot) = await request(.snapshot), epoch == self.epoch else { return }
        state = State(snapshot)
        onChange?()
        subscribeID = nextID
        // Channels exist only for `host.events.v1` peers, which serve it; a host
        // that predates `worktreeNotice`, `reviewStatus` or `reviewsChanged` just never matches that kind.
        _ = await request(.subscribeAccepting(after: snapshot.cursor, events: ["notice", "worktreeNotice", "reviewStatus", "reviewsChanged"])) // `finish` sets isSubscribed on .subscribed
    }

    /// Sends `request` and waits for its answer, or fails with
    /// `unansweredMessage` once `timeout` (the channel's by default) passes.
    public func request(_ request: HostRequest, timeout: Duration? = nil) async -> HostResponse {
        let id = nextID
        nextID += 1
        let timeout = timeout ?? self.timeout
        return await withCheckedContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(id, with: .failure(error: .failed(message: Self.unansweredMessage)))
            }
            pending[id] = (continuation, timeout)
            send(HostClientMessage(id: id, request: request))
        }
    }

    /// Something the peer sent. Answers to no pending request, and events
    /// outside a subscription, are dropped.
    public func receive(_ message: HostServerMessage) {
        switch message {
        case .response(let id, let result):
            finish(id, with: result)
        case .events(let events, _):
            guard isSubscribed, var next = state else { return }
            for case .notice(let notice) in events { onNotice?(notice) }
            for case .worktreeNotice(let notice) in events { onWorktreeNotice?(notice) }
            if events.contains(.resync) {
                isSubscribed = false
                onChange?()
                let epoch = self.epoch
                Task {
                    guard epoch == self.epoch else { return } // disconnected since
                    await connect()
                }
                return
            }
            for event in events { next.apply(event) }
            guard next != state else { return }
            state = next
            onChange?()
        }
    }

    /// Drops `worktreeID`'s cached review status, once the client no longer
    /// follows it: the host repeats no unchanged status on a later follow.
    public func forgetReviewStatus(worktreeID: String) {
        guard state?.reviewStatuses.removeValue(forKey: worktreeID) != nil else { return }
        onChange?()
    }

    /// Fails every pending request with the peer-unavailable message and
    /// forgets the peer's state.
    public func disconnect() {
        epoch += 1
        let failed = pending
        pending = [:]
        for (_, entry) in failed {
            entry.timeout.cancel()
            entry.continuation.resume(returning: .failure(error: .failed(message: FederatedSessionsProvider.peerUnavailableMessage)))
        }
        state = nil
        isSubscribed = false
        isConnecting = false
        subscribeID = nil
        onChange?()
    }

    private func finish(_ id: Int, with response: HostResponse) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        if id == subscribeID {
            subscribeID = nil
            if case .subscribed = response {
                isSubscribed = true
                onChange?() // reads gated on the subscription can start
            }
        }
        entry.timeout.cancel()
        entry.continuation.resume(returning: response)
    }
}
