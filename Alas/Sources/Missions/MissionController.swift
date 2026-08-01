import Foundation
import Observation

typealias MissionIssueRefresh = @MainActor (
    _ identity: MissionIssueIdentity,
    _ projectId: String
) async throws -> MissionIssueSnapshot

@Observable
@MainActor
final class MissionController {
    private(set) var aggregates: [MissionAggregate] = []
    private(set) var loadError: String?

    @ObservationIgnored
    private let persistence: MissionPersistence
    @ObservationIgnored
    private let environment: MissionCoordinator.Environment
    @ObservationIgnored
    private let issueRefresh: MissionIssueRefresh
    @ObservationIgnored
    private let projectExists: @MainActor (String) -> Bool
    @ObservationIgnored
    private let worktreeArchived: @MainActor (String, String) -> Bool
    @ObservationIgnored
    private let reviewSnapshot: @MainActor (String) -> ReviewLoopSnapshot?
    @ObservationIgnored
    private var lifecycleMutations: Set<MissionID> = []
    @ObservationIgnored
    private var lifecycleWaiters: [MissionID: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored
    private lazy var coordinator = MissionCoordinator(environment: .init(
        persistence: environment.persistence,
        now: environment.now,
        makeID: environment.makeID,
        worktreeAtDestination: environment.worktreeAtDestination,
        createWorktree: environment.createWorktree,
        startACP: environment.startACP,
        notifyChanged: { [weak self] aggregate in
            self?.environment.notifyChanged(aggregate)
            self?.replace(aggregate)
        },
        reportFailure: { [weak self] id, message in
            self?.environment.reportFailure(id, message)
            self?.loadError = message
        }
    ))

    init(
        environment: MissionCoordinator.Environment,
        issueRefresh: @escaping MissionIssueRefresh = { _, _ in
            throw CodeHostProviderError.malformedOutput("Issue refresh is unavailable.")
        },
        projectExists: @escaping @MainActor (String) -> Bool = { _ in true },
        worktreeArchived: @escaping @MainActor (String, String) -> Bool = { _, _ in false },
        reviewSnapshot: @escaping @MainActor (String) -> ReviewLoopSnapshot? = { _ in nil }
    ) {
        persistence = environment.persistence
        self.environment = environment
        self.issueRefresh = issueRefresh
        self.projectExists = projectExists
        self.worktreeArchived = worktreeArchived
        self.reviewSnapshot = reviewSnapshot
    }

    func load() async {
        do {
            aggregates = Self.sorted(try await persistence.list(includeCompleted: true))
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func create(_ draft: MissionDraft, allowDuplicate: Bool) async throws -> MissionID {
        let id = try await coordinator.create(draft, allowDuplicate: allowDuplicate)
        loadError = nil
        return id
    }

    func retry(_ id: MissionID, agentId: String? = nil) async {
        do {
            if let agentId,
               var aggregate = try await persistence.aggregate(id: id),
               aggregate.mission.state == .needsAttention,
               aggregate.mission.setupCheckpoint == .startingAgent,
               var leg = aggregate.primaryLeg {
                if leg.agentId != agentId {
                    leg.agentId = agentId
                    // ACP sessions retain their original agent identity. A replacement
                    // therefore needs a fresh, durable session ID instead of mutating
                    // the prior session or accidentally hydrating it for the new agent.
                    leg.acpSessionId = environment.makeID()
                    try await persistence.updateLeg(leg, event: nil)
                    aggregate.legs = [leg]
                    environment.notifyChanged(aggregate)
                    replace(aggregate)
                }
            }
            loadError = nil
            await coordinator.retry(id: id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func reconcileInterrupted() async {
        loadError = nil
        await coordinator.reconcileInterrupted()
        await reconcileReadinessAtStartup()
    }

    func observeReview(worktreeId: String, snapshot: ReviewLoopSnapshot) async {
        guard let request = snapshot.reviewRequest else { return }
        loadError = nil
        let identity = MissionReviewIdentity(
            provider: request.provider,
            host: request.remote.host,
            repositorySlug: request.remote.repositorySlug,
            number: request.number,
            url: request.url
        )
        do {
            let active = try await persistence.list(includeCompleted: false)
            for aggregate in active where aggregate.primaryLeg?.worktreeId == worktreeId {
                if let linked = aggregate.primaryLeg?.reviewIdentity, linked != identity {
                    continue
                }
                await apply(
                    signal: .review(state: request.state, identity: identity),
                    to: aggregate.mission.id
                )
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func recordArchive(worktreeId: String) async {
        loadError = nil
        do {
            let active = try await persistence.list(includeCompleted: false)
            for aggregate in active where aggregate.primaryLeg?.worktreeId == worktreeId {
                await apply(signal: .worktreeArchived, to: aggregate.mission.id)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func recordMissingWorktree(_ id: MissionID, projectRemoved: Bool = false) async {
        await apply(signal: projectRemoved ? .projectRemoved : .worktreeMissing, to: id)
    }

    func recordMissingWorktree(projectId: String, projectRemoved: Bool) async {
        loadError = nil
        do {
            let active = try await persistence.list(includeCompleted: false)
            for aggregate in active where aggregate.primaryLeg?.projectId == projectId {
                await recordMissingWorktree(
                    aggregate.mission.id,
                    projectRemoved: projectRemoved
                )
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refreshIssue(_ id: MissionID) async {
        do {
            guard let loaded = try await persistence.aggregate(id: id),
                  let leg = loaded.primaryLeg
            else { return }
            let refreshed: MissionIssueSnapshot
            do {
                refreshed = try await issueRefresh(loaded.issue.identity, leg.projectId)
            } catch {
                await persistRefreshFailure(error, aggregate: loaded)
                return
            }
            let event = makeEvent(
                aggregate: loaded,
                kind: .sourceRefreshed,
                message: "Issue #\(refreshed.identity.number) refreshed."
            )
            try await persistence.replaceIssueSnapshot(
                missionID: id,
                snapshot: refreshed,
                event: event
            )
            try await publish(id: id)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func complete(_ id: MissionID) async {
        await withLifecycleMutation(id: id) { [weak self] in
            guard let self else { return }
            do {
                guard let aggregate = try await persistence.aggregate(id: id),
                      [.running, .needsAttention, .readyToComplete].contains(aggregate.mission.state)
                else { return }
                let now = environment.now()
                let event = MissionEvent(
                    id: environment.makeID(),
                    missionID: id,
                    legID: aggregate.primaryLeg?.id,
                    kind: .completed,
                    message: "Mission completed.",
                    createdAt: now
                )
                try await persistence.complete(id: id, at: now, event: event)
                try await publish(id: id)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    func aggregate(id: MissionID) -> MissionAggregate? {
        aggregates.first { $0.mission.id == id }
    }

    private func reconcileReadinessAtStartup() async {
        loadError = nil
        do {
            let active = try await persistence.list(includeCompleted: false)
            for aggregate in active {
                guard let leg = aggregate.primaryLeg,
                      aggregate.mission.state != .creating
                else { continue }
                if !projectExists(leg.projectId) {
                    await recordMissingWorktree(aggregate.mission.id, projectRemoved: true)
                    continue
                }
                if worktreeArchived(leg.projectId, leg.destinationPath) {
                    await apply(signal: .worktreeArchived, to: aggregate.mission.id)
                    continue
                }
                guard environment.worktreeAtDestination(leg.projectId, leg.destinationPath) != nil else {
                    if aggregate.mission.setupCheckpoint == .running {
                        await recordMissingWorktree(aggregate.mission.id)
                    }
                    continue
                }
                if let worktreeID = leg.worktreeId,
                   let snapshot = reviewSnapshot(worktreeID) {
                    await observeReview(worktreeId: worktreeID, snapshot: snapshot)
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func apply(signal: MissionReadinessSignal, to id: MissionID) async {
        await withLifecycleMutation(id: id) { [weak self] in
            guard let self else { return }
            do {
                guard let aggregate = try await persistence.aggregate(id: id) else { return }
                let decision = MissionReadinessEvaluator.evaluate(
                    currentState: aggregate.mission.state,
                    signal: signal
                )
                switch decision {
                case .unchanged(let reviewIdentity):
                    guard aggregate.mission.state != .completed,
                          aggregate.primaryLeg?.reviewIdentity == nil,
                          let reviewIdentity,
                          var leg = aggregate.primaryLeg
                    else { return }
                    leg.reviewIdentity = reviewIdentity
                    try await persistence.updateLeg(
                        leg,
                        event: makeEvent(
                            aggregate: aggregate,
                            kind: .reviewLinked,
                            message: "\(reviewIdentity.provider.reviewRequestLabel) \(reviewIdentity.provider.reviewRequestNumberPrefix)\(reviewIdentity.number) linked."
                        )
                    )

                case .ready(let reviewIdentity, let message):
                    let linkedIdentity = aggregate.primaryLeg?.reviewIdentity ?? reviewIdentity
                    try await persistence.markReady(
                        id: id,
                        reviewIdentity: linkedIdentity,
                        event: makeEvent(aggregate: aggregate, kind: .ready, message: message)
                    )

                case .needsAttention(let message):
                    guard aggregate.mission.state != .needsAttention
                            || aggregate.mission.attentionReason != message
                    else { return }
                    try await persistence.updateSetup(
                        id: id,
                        state: .needsAttention,
                        checkpoint: aggregate.mission.setupCheckpoint,
                        attentionReason: message,
                        event: makeEvent(
                            aggregate: aggregate,
                            kind: .attentionRequired,
                            message: message
                        )
                    )
                }
                try await publish(id: id)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func makeEvent(
        aggregate: MissionAggregate,
        kind: MissionEventKind,
        message: String
    ) -> MissionEvent {
        MissionEvent(
            id: environment.makeID(),
            missionID: aggregate.mission.id,
            legID: aggregate.primaryLeg?.id,
            kind: kind,
            message: message,
            createdAt: environment.now()
        )
    }

    private func persistRefreshFailure(
        _ error: Error,
        aggregate: MissionAggregate
    ) async {
        var retained = aggregate.issue
        let message = Self.sanitized(error.localizedDescription)
        retained.refreshError = message
        let event = makeEvent(
            aggregate: aggregate,
            kind: .sourceRefreshed,
            message: "Issue refresh failed: \(message)"
        )
        do {
            try await persistence.replaceIssueSnapshot(
                missionID: aggregate.mission.id,
                snapshot: retained,
                event: event
            )
            try await publish(id: aggregate.mission.id)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func publish(id: MissionID) async throws {
        if let aggregate = try await persistence.aggregate(id: id) {
            replace(aggregate)
        }
    }

    private func withLifecycleMutation(
        id: MissionID,
        operation: @escaping @MainActor () async -> Void
    ) async {
        guard lifecycleMutations.insert(id).inserted else {
            await withCheckedContinuation { continuation in
                lifecycleWaiters[id, default: []].append(continuation)
            }
            await withLifecycleMutation(id: id, operation: operation)
            return
        }
        await operation()
        lifecycleMutations.remove(id)
        let waiters = lifecycleWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private static func sanitized(_ message: String) -> String {
        let collapsed = message
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let fallback = collapsed.isEmpty ? "Issue refresh failed." : collapsed
        return String(fallback.prefix(500))
    }

    private func replace(_ aggregate: MissionAggregate) {
        if let index = aggregates.firstIndex(where: { $0.mission.id == aggregate.mission.id }) {
            aggregates[index] = aggregate
        } else {
            aggregates.append(aggregate)
        }
        aggregates = Self.sorted(aggregates)
    }

    private static func sorted(_ aggregates: [MissionAggregate]) -> [MissionAggregate] {
        aggregates.sorted { lhs, rhs in
            let lhsCompleted = lhs.mission.state == .completed
            let rhsCompleted = rhs.mission.state == .completed
            if lhsCompleted != rhsCompleted { return !lhsCompleted }
            if lhs.mission.updatedAt != rhs.mission.updatedAt {
                return lhs.mission.updatedAt > rhs.mission.updatedAt
            }
            return lhs.mission.id.rawValue < rhs.mission.id.rawValue
        }
    }
}
