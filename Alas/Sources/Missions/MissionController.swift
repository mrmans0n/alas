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
    _ issueIdentity: MissionIssueIdentity,
    _ branch: String,
    _ baseRef: String,
    _ headSHA: String,
    _ headOwner: String?
) async -> ReviewRequest?

typealias MissionLinkedReviewRequest = @MainActor (
    _ identity: MissionReviewIdentity,
    _ projectID: String,
    _ baseRef: String
) async -> ReviewRequest?

typealias MissionBranchTip = @MainActor (
    _ projectID: String,
    _ branch: String
) async -> String?

typealias MissionBranchOwner = @MainActor (
    _ projectID: String,
    _ branch: String,
    _ issueIdentity: MissionIssueIdentity,
    _ baseRef: String
) async -> String?

typealias MissionLegacyBaseRemoteResolver = @MainActor (
    _ projectID: String,
    _ baseRef: String
) async -> String?

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
    private let branchTip: MissionBranchTip
    @ObservationIgnored
    private let branchOwner: MissionBranchOwner
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
        linkedReviewRequest: @escaping MissionLinkedReviewRequest = { _, _, _ in nil },
        branchTip: @escaping MissionBranchTip = { _, _ in nil },
        branchOwner: @escaping MissionBranchOwner = { _, _, _, _ in nil },
        projectExists: @escaping @MainActor (String) -> Bool = { _ in true },
        worktreeDiscoverySucceeded: @escaping @MainActor (String) -> Bool = { _ in true },
        worktreeArchived: @escaping @MainActor (String, String) -> Bool = { _, _ in false },
        reviewSnapshot: @escaping @MainActor (String, String) -> ReviewLoopSnapshot? = { _, _ in nil },
        startupReviewSnapshot: @escaping MissionStartupReviewSnapshot = { _, _ in nil },
        discoverReviewRequest: @escaping MissionReviewDiscovery = { _, _, _, _, _, _ in nil },
        openMission: @escaping @MainActor (MissionID) -> Void = { _ in }
    ) {
        persistence = environment.persistence
        self.environment = environment
        self.issueRefresh = issueRefresh
        self.linkedReviewRequest = linkedReviewRequest
        self.branchTip = branchTip
        self.branchOwner = branchOwner
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

    func resolveLegacyBaseRemoteNames(using resolver: MissionLegacyBaseRemoteResolver) async {
        do {
            var didChange = false
            for aggregate in try await persistence.list(includeCompleted: true) {
                for var leg in aggregate.legs where leg.baseRemoteName == nil {
                    guard let resolvedRemoteName = await resolver(leg.projectId, leg.baseRef) else { continue }
                    leg.baseRemoteName = resolvedRemoteName
                    try await persistence.updateLeg(leg, event: nil)
                    didChange = true
                }
            }
            if didChange { await load() }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func create(_ draft: MissionDraft, allowDuplicate: Bool) async throws -> MissionID {
        let id = try await coordinator.create(draft, allowDuplicate: allowDuplicate)
        loadError = nil
        return id
    }

    func addLeg(_ draft: MissionLegDraft, to missionID: MissionID) async throws -> MissionLegID {
        let legID = try await coordinator.addLeg(missionID: missionID, draft: draft)
        loadError = nil
        return legID
    }

    func retry(_ id: MissionID, agentId: String? = nil) async {
        guard let legID = aggregate(id: id)?.mission.primaryLegID else { return }
        await retry(id, legID: legID, agentId: agentId)
    }

    func retry(_ id: MissionID, legID: MissionLegID, agentId: String? = nil) async {
        await withLifecycleMutation(id: id) { [weak self] in
            guard let self else { return }
            do {
                var recreateWorktree = false
                if let agentId,
                   var aggregate = try await persistence.aggregate(id: id),
                   var leg = aggregate.legs.first(where: { $0.id == legID }),
                   leg.state == .needsAttention,
                   leg.setupCheckpoint == .startingAgent {
                    if leg.agentId != agentId {
                        leg.agentId = agentId
                        // ACP sessions retain their original agent identity. A replacement
                        // therefore needs a fresh, durable session ID instead of mutating
                        // the prior session or accidentally hydrating it for the new agent.
                        leg.acpSessionId = environment.makeID()
                        // Retry input is a prepared, persisted draft. Do not rebuild it from
                        // current issue state after a session has consumed it.
                        try await persistence.updateLeg(leg, event: nil)
                        aggregate.legs = aggregate.legs.map { $0.id == leg.id ? leg : $0 }
                        environment.notifyChanged(aggregate)
                        replace(aggregate)
                    }
                }
                if let aggregate = try await persistence.aggregate(id: id) {
                    recreateWorktree = aggregate.legs.first(where: { $0.id == legID })?.attentionReason
                        == MissionReadinessEvaluator.missingWorktreeMessage
                }
                loadError = nil
                await coordinator.retry(id: id, legID: legID, recreateWorktree: recreateWorktree)
            } catch {
                loadError = error.localizedDescription
            }
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
            for aggregate in active {
                for leg in aggregate.legs where leg.worktreeId == worktreeId {
                guard leg.baseRef == baseRef else { continue }
                guard let currentWorktree = environment.worktreeAtDestination(
                    leg.projectId,
                    leg.destinationPath
                ), currentWorktree.id == worktreeId,
                    currentWorktree.branch == leg.branch,
                    let worktreeLineageID = leg.worktreeLineageID,
                    currentWorktree.lineageID == worktreeLineageID
                else { continue }
                guard snapshot.local.branchName == leg.branch else { continue }
                let request: ReviewRequest
                var replacesLinkedReview = false
                if let linked = leg.reviewIdentity {
                    if let visible = snapshot.reviewRequest,
                       Self.review(visible, matches: linked) {
                        request = visible
                    } else if let refreshed = await linkedReviewRequest(
                        linked,
                        leg.projectId,
                        Self.baseBranch(for: leg)
                    ) {
                        let matchesCurrentHead = snapshot.local.headSHA.isEmpty
                            || refreshed.headSHA == snapshot.local.headSHA
                        if let visible = snapshot.reviewRequest,
                           refreshed.state == .closed
                           || !Self.review(
                               refreshed,
                               matches: leg,
                               issueIdentity: aggregate.issue.identity
                           )
                           || !matchesCurrentHead {
                            request = visible
                            replacesLinkedReview = true
                        } else {
                            request = refreshed
                        }
                    } else if let visible = snapshot.reviewRequest {
                        request = visible
                        replacesLinkedReview = true
                    } else {
                        continue
                    }
                } else if let visible = snapshot.reviewRequest {
                    request = visible
                } else {
                    continue
                }
                let identity = Self.reviewIdentity(for: request)
                guard Self.review(
                    request,
                    matches: leg,
                    issueIdentity: aggregate.issue.identity
                ) else { continue }
                guard request.state != .merged
                    || (!snapshot.local.headSHA.isEmpty && request.headSHA == snapshot.local.headSHA)
                else { continue }
                if let linked = leg.reviewIdentity,
                   !Self.sameReviewIdentity(linked, identity),
                   !replacesLinkedReview {
                    continue
                }
                await applyReview(
                    request,
                    identity: identity,
                    to: aggregate.mission.id,
                    legID: leg.id,
                    replaceReviewIdentity: replacesLinkedReview
                )
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func discoverMergedReview(worktreeId: String, baseRef: String, snapshot: ReviewLoopSnapshot) async {
        loadError = nil
        do {
            let active = try await persistence.list(includeCompleted: false)
            for aggregate in active {
                for leg in aggregate.legs where leg.worktreeId == worktreeId {
                guard leg.baseRef == baseRef,
                      let currentWorktree = environment.worktreeAtDestination(
                          leg.projectId,
                          leg.destinationPath
                      ), currentWorktree.id == worktreeId,
                      currentWorktree.branch == leg.branch,
                      let worktreeLineageID = leg.worktreeLineageID,
                      currentWorktree.lineageID == worktreeLineageID
                else { continue }
                let replacesLinkedReview = leg.reviewIdentity != nil
                guard let request = await discoverMergedReview(
                    for: leg,
                    issueIdentity: aggregate.issue.identity,
                    snapshot: snapshot
                ) else { continue }
                await applyReview(
                    request,
                    identity: Self.reviewIdentity(for: request),
                    to: aggregate.mission.id,
                    legID: leg.id,
                    replaceReviewIdentity: replacesLinkedReview
                )
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refreshReviewSnapshot(worktreeId: String, baseRef: String, snapshot: ReviewLoopSnapshot) async {
        await observeReview(worktreeId: worktreeId, baseRef: baseRef, snapshot: snapshot)
        await discoverMergedReview(worktreeId: worktreeId, baseRef: baseRef, snapshot: snapshot)
    }

    func recordArchive(worktreeId: String) async {
        loadError = nil
        do {
            let active = try await persistence.list(includeCompleted: false)
            for aggregate in active {
                for leg in aggregate.legs where leg.worktreeId == worktreeId {
                guard let currentWorktree = environment.worktreeAtDestination(
                          leg.projectId,
                          leg.destinationPath
                      ), currentWorktree.id == worktreeId,
                      currentWorktree.branch == leg.branch,
                      worktreeArchived(leg.projectId, leg.destinationPath)
                else { continue }
                await applyArchive(to: aggregate.mission.id, legID: leg.id)
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func recordMissingWorktree(_ id: MissionID, projectRemoved: Bool = false) async {
        guard let legID = aggregate(id: id)?.mission.primaryLegID else { return }
        await recordMissingWorktree(id, legID: legID, projectRemoved: projectRemoved)
    }

    func recordMissingWorktree(_ id: MissionID, legID: MissionLegID, projectRemoved: Bool = false) async {
        await apply(
            signal: projectRemoved ? .projectRemoved : .worktreeMissing,
            to: id,
            legID: legID
        )
    }

    func recordAvailableWorktree(_ id: MissionID) async {
        await restoreReappearedWorktreeIfNeeded(id)
    }

    func recordAvailableWorktree(_ id: MissionID, legID: MissionLegID) async {
        await restoreReappearedWorktreeIfNeeded(id, legID: legID)
    }

    func recordMissingWorktree(projectId: String, projectRemoved: Bool) async {
        loadError = nil
        do {
            let active = try await persistence.list(includeCompleted: false)
            for aggregate in active {
                for leg in aggregate.legs where leg.projectId == projectId {
                    await recordMissingWorktree(
                        aggregate.mission.id,
                        legID: leg.id,
                        projectRemoved: projectRemoved
                    )
                }
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
            let updatedMissionIDs = try await persistence.replaceIssueSnapshot(
                missionID: id,
                snapshot: refreshed,
                event: event
            )
            for updatedMissionID in updatedMissionIDs {
                try await publish(id: updatedMissionID)
            }
            loadError = nil
        } catch {
            guard issueRefreshGenerations[id] == generation else { return }
            loadError = error.localizedDescription
        }
    }

    func refreshLinkedReview(_ id: MissionID) async {
        do {
            guard let aggregate = try await persistence.aggregate(id: id) else { return }
            for leg in aggregate.legs where leg.reviewIdentity != nil {
                await refreshLinkedReview(id, legID: leg.id)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refreshLinkedReview(_ id: MissionID, legID: MissionLegID) async {
        do {
            guard let aggregate = try await persistence.aggregate(id: id),
                  let leg = aggregate.legs.first(where: { $0.id == legID }),
                  let identity = leg.reviewIdentity,
                  let request = await linkedReviewRequest(identity, leg.projectId, Self.baseBranch(for: leg)),
                  Self.review(request, matches: leg, issueIdentity: aggregate.issue.identity)
            else { return }
            if request.state == .merged {
                guard let currentTip = await branchTip(leg.projectId, leg.branch),
                      !currentTip.isEmpty,
                      request.headSHA == currentTip
                else { return }
            }
            await applyReview(request, identity: identity, to: id, legID: legID)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refreshReviewWithoutWorktree(_ id: MissionID) async {
        do {
            guard let aggregate = try await persistence.aggregate(id: id) else { return }
            for leg in aggregate.legs {
                await refreshReviewWithoutWorktree(for: aggregate, leg: leg)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refreshReviewBeforeWorktreeRemoval(_ worktreeID: String) async -> Bool {
        loadError = nil
        do {
            let active = try await persistence.list(includeCompleted: false)
            for aggregate in active {
                for leg in aggregate.legs where leg.worktreeId == worktreeID {
                    await refreshReviewWithoutWorktree(for: aggregate, leg: leg)
                    guard let refreshed = try await persistence.aggregate(id: aggregate.mission.id),
                          refreshed.legs.first(where: { $0.id == leg.id })?.readinessEvidence != nil
                    else { return false }
                }
            }
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    func complete(_ id: MissionID) async {
        await withLifecycleMutation(id: id) { [weak self] in
            guard let self else { return }
            do {
                guard let aggregate = try await persistence.aggregate(id: id),
                      [.running, .needsAttention, .readyToComplete].contains(aggregate.mission.state)
                else { return }
                var leg = aggregate.primaryLeg
                if var currentLeg = leg,
                   let worktree = environment.worktreeAtDestination(
                       currentLeg.projectId,
                       currentLeg.destinationPath
                   ), worktree.id == currentLeg.worktreeId,
                   worktree.branch == currentLeg.branch,
                   worktree.path.standardizedFileURL.path
                   == URL(fileURLWithPath: currentLeg.destinationPath).standardizedFileURL.path,
                   currentLeg.worktreeLineageID == nil
                   || currentLeg.worktreeLineageID == worktree.lineageID {
                    currentLeg.worktreeLineageID = worktree.lineageID
                    leg = currentLeg
                }
                let now = environment.now()
                let event = MissionEvent(
                    id: environment.makeID(),
                    missionID: id,
                    legID: aggregate.primaryLeg?.id,
                    kind: .completed,
                    message: "Mission completed.",
                    createdAt: now
                )
                try await persistence.complete(id: id, leg: leg, at: now, event: event)
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
                && aggregate.legs.contains { $0.worktreeId == worktreeId }
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
                for leg in aggregate.legs {
                guard aggregate.mission.state != .completed,
                      leg.state != .creating,
                      leg.setupCheckpoint != .creatingWorktree
                else { continue }
                if !projectExists(leg.projectId) {
                    await recordMissingWorktree(aggregate.mission.id, legID: leg.id, projectRemoved: true)
                    continue
                }
                guard let worktree = environment.worktreeAtDestination(leg.projectId, leg.destinationPath) else {
                    if worktreeDiscoverySucceeded(leg.projectId) {
                        await recordMissingWorktree(aggregate.mission.id, legID: leg.id)
                    }
                    await refreshReviewWithoutWorktree(for: aggregate, leg: leg)
                    continue
                }
                guard worktree.branch == leg.branch else {
                    if worktreeDiscoverySucceeded(leg.projectId) {
                        await recordMissingWorktree(aggregate.mission.id, legID: leg.id)
                    }
                    await refreshReviewWithoutWorktree(for: aggregate, leg: leg)
                    continue
                }
                guard let worktreeLineageID = leg.worktreeLineageID,
                      worktree.lineageID == worktreeLineageID
                else {
                    if worktreeDiscoverySucceeded(leg.projectId) {
                        await recordMissingWorktree(aggregate.mission.id, legID: leg.id)
                    }
                    await refreshReviewWithoutWorktree(for: aggregate, leg: leg)
                    continue
                }
                await restoreReappearedWorktreeIfNeeded(aggregate.mission.id, legID: leg.id)
                if worktreeArchived(leg.projectId, leg.destinationPath) {
                    await applyArchive(to: aggregate.mission.id, legID: leg.id)
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
                if let worktreeID = leg.worktreeId,
                   let snapshot {
                    await discoverMergedReview(
                        worktreeId: worktreeID,
                        baseRef: leg.baseRef,
                        snapshot: snapshot
                    )
                }
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func discoverMergedReview(
        for leg: MissionLeg,
        issueIdentity: MissionIssueIdentity,
        snapshot: ReviewLoopSnapshot
    ) async -> ReviewRequest? {
        guard snapshot.local.branchName == leg.branch else { return nil }
        let resolvedOwner = await branchOwner(
            leg.projectId,
            leg.branch,
            issueIdentity,
            leg.baseRef
        )
        let headOwner = if let resolvedOwner, !resolvedOwner.isEmpty {
            resolvedOwner
        } else {
            snapshot.local.headRemoteOwner
        }
        guard let headOwner,
              !headOwner.isEmpty,
              let request = await discoverMergedReview(
                  for: leg,
                  issueIdentity: issueIdentity,
                  headSHA: snapshot.local.headSHA,
                  headOwner: headOwner
              )
        else { return nil }
        return request
    }

    private func discoverMergedReview(
        for leg: MissionLeg,
        issueIdentity: MissionIssueIdentity,
        headSHA: String,
        headOwner: String?
    ) async -> ReviewRequest? {
        guard !headSHA.isEmpty,
              let request = await discoverReviewRequest(
                  leg.projectId,
                  issueIdentity,
                  leg.branch,
                  Self.baseBranch(for: leg),
                  headSHA,
                  headOwner
              ),
              request.headRefName == leg.branch,
              request.headSHA == headSHA,
              request.state == .merged,
              Self.review(request, matches: leg, issueIdentity: issueIdentity)
        else { return nil }
        return request
    }

    private func refreshReviewWithoutWorktree(for aggregate: MissionAggregate, leg: MissionLeg) async {
        if let currentWorktree = environment.worktreeAtDestination(
            leg.projectId,
            leg.destinationPath
        ) {
            guard currentWorktree.id == leg.worktreeId,
                  currentWorktree.branch == leg.branch,
                  let worktreeLineageID = leg.worktreeLineageID,
                  currentWorktree.lineageID == worktreeLineageID
            else { return }
        }
        let currentTip = await branchTip(leg.projectId, leg.branch)
        var replacesLinkedReview = false
        if let identity = leg.reviewIdentity {
            if let linked = await linkedReviewRequest(identity, leg.projectId, Self.baseBranch(for: leg)),
               Self.review(linked, matches: identity) {
                let matchesCurrentTip: Bool
                if let currentTip, !currentTip.isEmpty {
                    matchesCurrentTip = linked.headSHA == currentTip
                } else {
                    matchesCurrentTip = true
                }
                if linked.state != .closed,
                   Self.review(linked, matches: leg, issueIdentity: aggregate.issue.identity),
                   matchesCurrentTip {
                    if linked.state == .merged {
                        guard let currentTip,
                              !currentTip.isEmpty,
                              linked.headSHA == currentTip
                        else { return }
                        await applyReview(linked, identity: identity, to: aggregate.mission.id, legID: leg.id)
                        return
                    }
                    await applyReview(linked, identity: identity, to: aggregate.mission.id, legID: leg.id)
                }
                if linked.state == .closed {
                    await applyReview(linked, identity: identity, to: aggregate.mission.id, legID: leg.id)
                }
            }
            replacesLinkedReview = true
        }
        guard let currentTip,
              !currentTip.isEmpty,
              let headOwner = await branchOwner(
                  leg.projectId,
                  leg.branch,
                  aggregate.issue.identity,
                  leg.baseRef
              ),
              !headOwner.isEmpty,
              let request = await discoverMergedReview(
                  for: leg,
                  issueIdentity: aggregate.issue.identity,
                  headSHA: currentTip,
                  headOwner: headOwner
              )
        else { return }
        await applyReview(
            request,
            identity: Self.reviewIdentity(for: request),
            to: aggregate.mission.id,
            legID: leg.id,
            replaceReviewIdentity: replacesLinkedReview
        )
    }

    private func restoreReappearedWorktreeIfNeeded(_ id: MissionID, legID: MissionLegID? = nil) async {
        await withLifecycleMutation(id: id) { [weak self] in
            guard let self else { return }
            do {
                guard let aggregate = try await persistence.aggregate(id: id) else { return }
                let legs = if let legID {
                    aggregate.legs.filter { $0.id == legID }
                } else {
                    aggregate.legs
                }
                for leg in legs {
                    guard leg.state == .needsAttention,
                          leg.setupCheckpoint == .running,
                          leg.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage,
                          let worktree = environment.worktreeAtDestination(
                              leg.projectId,
                              leg.destinationPath
                          ),
                          worktree.branch == leg.branch,
                          let worktreeLineageID = leg.worktreeLineageID,
                          worktree.lineageID == worktreeLineageID
                    else { continue }
                    var restored = leg
                    restored.attentionReason = nil
                    restored.updatedAt = environment.now()
                    if restored.pendingInitialPrompt != nil {
                        restored.state = .creating
                        restored.setupCheckpoint = .startingAgent
                        try await persistence.updateLeg(
                            restored,
                            event: makeEvent(
                                aggregate: aggregate,
                                legID: leg.id,
                                kind: .retryStarted,
                                message: "Mission worktree became available again. Resuming agent setup."
                            )
                        )
                        try await publish(id: id)
                        await coordinator.advance(id: id, legID: leg.id)
                    } else {
                        restored.state = .running
                        restored.setupCheckpoint = .running
                        try await persistence.updateLeg(
                            restored,
                            event: makeEvent(
                                aggregate: aggregate,
                                legID: leg.id,
                                kind: .retryStarted,
                                message: "Mission worktree became available again."
                            )
                        )
                        try await publish(id: id)
                    }
                }
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func applyReview(
        _ request: ReviewRequest,
        identity: MissionReviewIdentity,
        to id: MissionID,
        legID: MissionLegID? = nil,
        replaceReviewIdentity: Bool = false
    ) async {
        await apply(
            signal: .review(state: request.state, identity: identity),
            to: id,
            legID: legID,
            replaceReviewIdentity: replaceReviewIdentity,
            validate: { [weak self] aggregate in
                guard request.state == .merged else { return true }
                guard let self,
                      let leg = legID.flatMap({ target in aggregate.legs.first { $0.id == target } })
                        ?? aggregate.primaryLeg,
                      let currentTip = await branchTip(leg.projectId, leg.branch),
                      !currentTip.isEmpty
                else { return false }
                return request.headSHA == currentTip
                    && Self.review(request, matches: leg, issueIdentity: aggregate.issue.identity)
            }
        )
    }

    private func applyArchive(to id: MissionID, legID: MissionLegID? = nil) async {
        await apply(
            signal: .worktreeArchived,
            to: id,
            legID: legID,
            validate: { [weak self] aggregate in
                guard let self,
                      let leg = legID.flatMap({ target in aggregate.legs.first { $0.id == target } })
                        ?? aggregate.primaryLeg,
                      let currentWorktree = environment.worktreeAtDestination(
                          leg.projectId,
                          leg.destinationPath
                      ),
                      currentWorktree.id == leg.worktreeId,
                      currentWorktree.branch == leg.branch,
                      let worktreeLineageID = leg.worktreeLineageID,
                      currentWorktree.lineageID == worktreeLineageID
                else { return false }
                return worktreeArchived(leg.projectId, leg.destinationPath)
            }
        )
    }

    private func apply(
        signal: MissionReadinessSignal,
        to id: MissionID,
        legID: MissionLegID? = nil,
        replaceReviewIdentity: Bool = false,
        validate: @escaping @MainActor (MissionAggregate) async -> Bool = { _ in true }
    ) async {
        await withLifecycleMutation(id: id) { [weak self] in
            guard let self else { return }
            do {
                guard var aggregate = try await persistence.aggregate(id: id) else { return }
                guard let targetLegID = legID ?? aggregate.primaryLeg?.id else { return }
                let setupWasCreating = aggregate.legs.first(where: { $0.id == targetLegID })?.state == .creating
                if setupWasCreating {
                    await coordinator.advance(id: id, legID: targetLegID)
                    guard let settled = try await persistence.aggregate(id: id),
                          settled.legs.first(where: { $0.id == targetLegID })?.state != .creating
                    else { return }
                    aggregate = settled
                }
                guard await validate(aggregate) else { return }
                guard let targetLeg = aggregate.legs.first(where: { $0.id == targetLegID }) else { return }
                let decision = MissionReadinessEvaluator.evaluate(
                    currentState: targetLeg.state,
                    signal: signal,
                    observedAt: environment.now()
                )
                switch decision {
                case .unchanged(let reviewIdentity):
                    guard aggregate.mission.state != .completed,
                          let reviewIdentity,
                          var leg = aggregate.legs.first(where: { $0.id == targetLegID }),
                          leg.reviewIdentity != reviewIdentity,
                          leg.reviewIdentity == nil || replaceReviewIdentity
                    else { return }
                    leg.reviewIdentity = reviewIdentity
                    try await persistence.updateLeg(
                        leg,
                        event: makeEvent(
                            aggregate: aggregate,
                            legID: targetLegID,
                            kind: .reviewLinked,
                            message: "\(reviewIdentity.provider.reviewRequestLabel) \(reviewIdentity.provider.reviewRequestNumberPrefix)\(reviewIdentity.number) linked."
                        )
                    )

                case .ready(let reviewIdentity, let evidence, let message):
                    let linkedIdentity = replaceReviewIdentity
                        ? reviewIdentity
                        : targetLeg.reviewIdentity ?? reviewIdentity
                    var leg = targetLeg
                    leg.reviewIdentity = linkedIdentity
                    leg.state = .ready
                    leg.setupCheckpoint = .running
                    leg.attentionReason = nil
                    leg.readinessEvidence = evidence
                    leg.updatedAt = evidence.observedAt
                    try await persistence.updateLeg(
                        leg,
                        event: makeEvent(
                            aggregate: aggregate,
                            legID: targetLegID,
                            kind: .ready,
                            message: message
                        )
                    )

                case .needsAttention(let message):
                    guard targetLeg.state != .needsAttention
                            || targetLeg.attentionReason != message
                    else { return }
                    var leg = targetLeg
                    if case .worktreeMissing = signal,
                       leg.pendingInitialPrompt == nil {
                        // Losing the worktree creates a fresh delegation target; the
                        // prior prompt receipt belongs to the vanished session.
                        leg.pendingInitialPrompt = MissionPromptBuilder.build(snapshot: aggregate.issue)
                    }
                    leg.state = .needsAttention
                    leg.setupCheckpoint = if case .worktreeMissing = signal { .running } else { targetLeg.setupCheckpoint }
                    leg.attentionReason = message
                    leg.updatedAt = environment.now()
                    try await persistence.updateLeg(
                        leg,
                        event: makeEvent(
                            aggregate: aggregate,
                            legID: targetLegID,
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
        legID: MissionLegID? = nil,
        kind: MissionEventKind,
        message: String
    ) -> MissionEvent {
        MissionEvent(
            id: environment.makeID(),
            missionID: aggregate.mission.id,
            legID: legID ?? aggregate.primaryLeg?.id,
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
            environment.notifyChanged(aggregate)
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

    private static func review(_ request: ReviewRequest, matches identity: MissionReviewIdentity) -> Bool {
        sameReviewIdentity(reviewIdentity(for: request), identity)
    }

    private static func sameReviewIdentity(
        _ lhs: MissionReviewIdentity,
        _ rhs: MissionReviewIdentity
    ) -> Bool {
        lhs.provider == rhs.provider
            && lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame
            && lhs.repositorySlug.caseInsensitiveCompare(rhs.repositorySlug) == .orderedSame
            && lhs.number == rhs.number
    }

    private static func review(
        _ request: ReviewRequest,
        matches leg: MissionLeg,
        issueIdentity: MissionIssueIdentity
    ) -> Bool {
        let expectedBase = MissionBaseReference.branchName(
            leg.baseRef,
            persistedRemoteName: leg.baseRemoteName
        )
        return request.provider == issueIdentity.provider
            && request.remote.host.caseInsensitiveCompare(issueIdentity.host) == .orderedSame
            && request.remote.repositorySlug.caseInsensitiveCompare(issueIdentity.repositorySlug) == .orderedSame
            && request.headRefName == leg.branch
            && request.baseRefName == expectedBase
    }

    private static func baseBranch(for leg: MissionLeg) -> String {
        MissionBaseReference.branchName(
            leg.baseRef,
            persistedRemoteName: leg.baseRemoteName
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
