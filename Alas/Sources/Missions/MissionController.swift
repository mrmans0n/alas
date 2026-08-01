import Foundation
import Observation

typealias MissionIssueRefresh = @MainActor (
    _ identity: MissionIssueIdentity,
    _ projectId: String
) async throws -> MissionIssueSnapshot

typealias MissionStartupReviewSnapshot = @MainActor (
    _ worktree: Worktree,
    _ baseRef: String
) async -> ReviewLoopSnapshot?

typealias MissionReviewDiscovery = @MainActor (
    _ projectID: String,
    _ branch: String,
    _ baseRef: String
) async -> ReviewRequest?

typealias MissionLinkedReviewRequest = @MainActor (
    _ identity: MissionReviewIdentity,
    _ projectID: String
) async -> ReviewRequest?

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
    private let linkedReviewRequest: MissionLinkedReviewRequest
    @ObservationIgnored
    private let projectExists: @MainActor (String) -> Bool
    @ObservationIgnored
    private let worktreeDiscoverySucceeded: @MainActor (String) -> Bool
    @ObservationIgnored
    private let worktreeArchived: @MainActor (String, String) -> Bool
    @ObservationIgnored
    private let reviewSnapshot: @MainActor (String, String) -> ReviewLoopSnapshot?
    @ObservationIgnored
    private let startupReviewSnapshot: MissionStartupReviewSnapshot
    @ObservationIgnored
    private let discoverReviewRequest: MissionReviewDiscovery
    @ObservationIgnored
    private let openMission: @MainActor (MissionID) -> Void
    @ObservationIgnored
    private var lifecycleMutations: Set<MissionID> = []
    @ObservationIgnored
    private var lifecycleWaiters: [MissionID: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored
    private var issueRefreshGenerations: [MissionID: Int] = [:]
    @ObservationIgnored
    private lazy var coordinator = MissionCoordinator(environment: .init(
        persistence: environment.persistence,
        now: environment.now,
        makeID: environment.makeID,
        plannedWorktreeID: environment.plannedWorktreeID,
        worktreeAtDestination: environment.worktreeAtDestination,
        createWorktree: environment.createWorktree,
        startACP: environment.startACP,
        notifyChanged: { [weak self] aggregate in
            self?.environment.notifyChanged(aggregate)
            self?.replace(aggregate)
        },
        didCreateWorktree: { [weak self] missionID in
            self?.openMission(missionID)
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
        linkedReviewRequest: @escaping MissionLinkedReviewRequest = { _, _ in nil },
        projectExists: @escaping @MainActor (String) -> Bool = { _ in true },
        worktreeDiscoverySucceeded: @escaping @MainActor (String) -> Bool = { _ in true },
        worktreeArchived: @escaping @MainActor (String, String) -> Bool = { _, _ in false },
        reviewSnapshot: @escaping @MainActor (String, String) -> ReviewLoopSnapshot? = { _, _ in nil },
        startupReviewSnapshot: @escaping MissionStartupReviewSnapshot = { _, _ in nil },
        discoverReviewRequest: @escaping MissionReviewDiscovery = { _, _, _ in nil },
        openMission: @escaping @MainActor (MissionID) -> Void = { _ in }
    ) {
        persistence = environment.persistence
        self.environment = environment
        self.issueRefresh = issueRefresh
        self.linkedReviewRequest = linkedReviewRequest
        self.projectExists = projectExists
        self.worktreeDiscoverySucceeded = worktreeDiscoverySucceeded
        self.worktreeArchived = worktreeArchived
        self.reviewSnapshot = reviewSnapshot
        self.startupReviewSnapshot = startupReviewSnapshot
        self.discoverReviewRequest = discoverReviewRequest
        self.openMission = openMission
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
            var recreateWorktree = false
            if let agentId,
               var aggregate = try await persistence.aggregate(id: id),
               aggregate.mission.state == .needsAttention,
               aggregate.mission.setupCheckpoint == .startingAgent,
               var leg = aggregate.primaryLeg {
                if leg.agentId != agentId, leg.pendingInitialPrompt != nil {
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
            if let aggregate = try await persistence.aggregate(id: id) {
                recreateWorktree = aggregate.mission.state == .needsAttention
                    && aggregate.mission.setupCheckpoint == .running
                    && aggregate.mission.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage
            }
            loadError = nil
            await coordinator.retry(id: id, recreateWorktree: recreateWorktree)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func reconcileInterrupted() async {
        loadError = nil
        await coordinator.reconcileInterrupted()
        await reconcileReadinessAtStartup()
    }

    func observeReview(worktreeId: String, baseRef: String, snapshot: ReviewLoopSnapshot) async {
        loadError = nil
        do {
            let active = try await persistence.list(includeCompleted: false)
            for aggregate in active where aggregate.primaryLeg?.worktreeId == worktreeId {
                guard let leg = aggregate.primaryLeg else { continue }
                guard leg.baseRef == baseRef else { continue }
                guard let currentWorktree = environment.worktreeAtDestination(
                    leg.projectId,
                    leg.destinationPath
                ), currentWorktree.id == worktreeId,
                    currentWorktree.branch == leg.branch
                else { continue }
                guard snapshot.local.branchName == leg.branch else { continue }
                let request: ReviewRequest
                if let linked = leg.reviewIdentity {
                    if let visible = snapshot.reviewRequest,
                       Self.reviewIdentity(for: visible) == linked {
                        request = visible
                    } else if let refreshed = await linkedReviewRequest(linked, leg.projectId) {
                        request = refreshed
                    } else {
                        continue
                    }
                } else if let visible = snapshot.reviewRequest {
                    request = visible
                } else {
                    continue
                }
                let identity = Self.reviewIdentity(for: request)
                guard request.headRefName == leg.branch else { continue }
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
                guard let leg = aggregate.primaryLeg,
                      let currentWorktree = environment.worktreeAtDestination(
                          leg.projectId,
                          leg.destinationPath
                      ), currentWorktree.id == worktreeId,
                      currentWorktree.branch == leg.branch
                else { continue }
                await apply(signal: .worktreeArchived, to: aggregate.mission.id)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func recordMissingWorktree(_ id: MissionID, projectRemoved: Bool = false) async {
        await apply(signal: projectRemoved ? .projectRemoved : .worktreeMissing, to: id)
    }

    func recordAvailableWorktree(_ id: MissionID) async {
        await restoreReappearedWorktreeIfNeeded(id)
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
        issueRefreshGenerations[id, default: 0] &+= 1
        let generation = issueRefreshGenerations[id, default: 0]
        do {
            guard let loaded = try await persistence.aggregate(id: id),
                  let leg = loaded.primaryLeg
            else { return }
            let refreshed: MissionIssueSnapshot
            do {
                refreshed = try await issueRefresh(loaded.issue.identity, leg.projectId)
            } catch {
                guard issueRefreshGenerations[id] == generation else { return }
                await persistRefreshFailure(error, aggregate: loaded)
                return
            }
            guard issueRefreshGenerations[id] == generation else { return }
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
            guard issueRefreshGenerations[id] == generation else { return }
            loadError = error.localizedDescription
        }
    }

    func refreshLinkedReview(_ id: MissionID) async {
        do {
            guard let aggregate = try await persistence.aggregate(id: id),
                  let leg = aggregate.primaryLeg,
                  let identity = leg.reviewIdentity,
                  let request = await linkedReviewRequest(identity, leg.projectId)
            else { return }
            await apply(
                signal: .review(state: request.state, identity: identity),
                to: id
            )
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

    func hasActiveMission(worktreeId: String) -> Bool {
        aggregates.contains { aggregate in
            aggregate.mission.state != .completed
                && aggregate.primaryLeg?.worktreeId == worktreeId
        }
    }

    func sidebarModel(
        activeProjectIds: [String],
        existingProjectIds: [String],
        knownWorktreeIds: Set<String>
    ) -> MissionSidebarModel {
        MissionSidebarModel.make(
            aggregates: aggregates,
            activeProjectIds: activeProjectIds,
            existingProjectIds: existingProjectIds,
            knownWorktreeIds: knownWorktreeIds
        )
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
                guard let worktree = environment.worktreeAtDestination(leg.projectId, leg.destinationPath) else {
                    if aggregate.mission.setupCheckpoint == .running,
                       worktreeDiscoverySucceeded(leg.projectId) {
                        await recordMissingWorktree(aggregate.mission.id)
                    }
                    await refreshLinkedReview(aggregate.mission.id)
                    continue
                }
                guard worktree.branch == leg.branch else {
                    if aggregate.mission.setupCheckpoint == .running {
                        await recordMissingWorktree(aggregate.mission.id)
                    }
                    continue
                }
                await restoreReappearedWorktreeIfNeeded(aggregate.mission.id)
                if worktreeArchived(leg.projectId, leg.destinationPath) {
                    await apply(signal: .worktreeArchived, to: aggregate.mission.id)
                    continue
                }
                let snapshot: ReviewLoopSnapshot?
                if let worktreeID = leg.worktreeId,
                   let cached = reviewSnapshot(worktreeID, leg.baseRef) {
                    snapshot = cached
                } else {
                    snapshot = await startupReviewSnapshot(worktree, leg.baseRef)
                }
                if let worktreeID = leg.worktreeId,
                   let snapshot {
                    await observeReview(
                        worktreeId: worktreeID,
                        baseRef: leg.baseRef,
                        snapshot: snapshot
                    )
                }
                if leg.reviewIdentity == nil,
                   snapshot?.reviewRequest == nil,
                   let request = await discoverReviewRequest(
                       leg.projectId,
                       leg.branch,
                       leg.baseRef
                   ),
                   request.headRefName == leg.branch {
                    await apply(
                        signal: .review(
                            state: request.state,
                            identity: Self.reviewIdentity(for: request)
                        ),
                        to: aggregate.mission.id
                    )
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func restoreReappearedWorktreeIfNeeded(_ id: MissionID) async {
        await withLifecycleMutation(id: id) { [weak self] in
            guard let self else { return }
            do {
                guard let aggregate = try await persistence.aggregate(id: id),
                      aggregate.mission.state == .needsAttention,
                      aggregate.mission.setupCheckpoint == .running,
                      aggregate.mission.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage,
                      let leg = aggregate.primaryLeg,
                      let worktree = environment.worktreeAtDestination(
                          leg.projectId,
                          leg.destinationPath
                      ),
                      worktree.branch == leg.branch
                else { return }
                try await persistence.updateSetup(
                    id: id,
                    state: .running,
                    checkpoint: .running,
                    attentionReason: nil,
                    event: makeEvent(
                        aggregate: aggregate,
                        kind: .retryStarted,
                        message: "Mission worktree became available again."
                    )
                )
                try await publish(id: id)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func apply(signal: MissionReadinessSignal, to id: MissionID) async {
        await withLifecycleMutation(id: id) { [weak self] in
            guard let self else { return }
            do {
                guard var aggregate = try await persistence.aggregate(id: id) else { return }
                let setupWasCreating = aggregate.mission.state == .creating
                if setupWasCreating {
                    await coordinator.advance(id: id)
                    guard let settled = try await persistence.aggregate(id: id),
                          settled.mission.state != .creating
                    else { return }
                    aggregate = settled
                }
                let decision = MissionReadinessEvaluator.evaluate(
                    currentState: aggregate.mission.state,
                    signal: signal
                )
                if setupWasCreating,
                   aggregate.mission.state != .running,
                   case .ready = decision {
                    return
                }
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
        let message = Self.sanitized(error.localizedDescription)
        let event = makeEvent(
            aggregate: aggregate,
            kind: .sourceRefreshed,
            message: "Issue refresh failed: \(message)"
        )
        do {
            try await persistence.updateIssueRefreshError(
                missionID: aggregate.mission.id,
                refreshError: message,
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

    private static func reviewIdentity(for request: ReviewRequest) -> MissionReviewIdentity {
        MissionReviewIdentity(
            provider: request.provider,
            host: request.remote.host,
            repositorySlug: request.remote.repositorySlug,
            number: request.number,
            url: request.url
        )
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
