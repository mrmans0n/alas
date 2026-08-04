import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct MissionReadinessEvaluatorTests {
    private static let missionID = MissionID(rawValue: "mission-1")
    private static let reviewIdentity = MissionReviewIdentity(
        provider: .github,
        host: "github.com",
        repositorySlug: "acme/alas",
        number: 91,
        url: URL(string: "https://github.com/acme/alas/pull/91")!
    )

    @Test func mergedReviewMakesRunningLegReadyWithStickyEvidence() {
        let observedAt = Date(timeIntervalSince1970: 101)
        let decision = MissionReadinessEvaluator.evaluate(
            currentState: .running,
            signal: .review(state: .merged, identity: Self.reviewIdentity),
            observedAt: observedAt
        )

        #expect(decision == .ready(
            reviewIdentity: Self.reviewIdentity,
            evidence: .init(kind: .mergedReview, observedAt: observedAt),
            message: "PR #91 merged."
        ))
    }

    @Test func openReviewLinksWithoutMakingLegReady() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .running,
            signal: .review(state: .open, identity: Self.reviewIdentity),
            observedAt: Date(timeIntervalSince1970: 101)
        ) == .unchanged(reviewIdentity: Self.reviewIdentity))
    }

    @Test func closedUnmergedReviewDoesNotMakeMissionReady() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .running,
            signal: .review(state: .closed, identity: Self.reviewIdentity),
            observedAt: Date(timeIntervalSince1970: 101)
        ) == .unchanged(reviewIdentity: Self.reviewIdentity))
    }

    @Test func explicitArchiveMakesRunningLegReady() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .running,
            signal: .worktreeArchived,
            observedAt: Date(timeIntervalSince1970: 101)
        ) == .ready(
            reviewIdentity: nil,
            evidence: .init(kind: .archivedWorktree, observedAt: Date(timeIntervalSince1970: 101)),
            message: "Worktree archived in Alas."
        ))
    }

    @Test func externallyMissingWorktreeNeedsAttention() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .running,
            signal: .worktreeMissing,
            observedAt: Date(timeIntervalSince1970: 101)
        ) == .needsAttention("The Mission worktree is no longer available."))
    }

    @Test func missingWorktreeAfterAgentFailureResetsToRecreationCheckpoint() async throws {
        var failedAgent = Self.runningAggregate()
        failedAgent.markPrimaryLegNeedsAttention(
            checkpoint: .startingAgent,
            reason: "ACP setup failed."
        )
        let fake = try MissionLifecycleFake(aggregate: failedAgent, worktreeAvailable: false)
        await fake.controller.load()

        await fake.controller.recordMissingWorktree(Self.missionID)
        var aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .running)
        #expect(aggregate.mission.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)

        await fake.controller.retry(Self.missionID)
        aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(fake.externalOperations == ["createWorktree"])
        #expect(aggregate.mission.setupCheckpoint == .creatingWorktree)
    }

    @Test func missingLegacyPrimaryWorktreeReconstructsAConsumedPrompt() async throws {
        var legacy = Self.runningAggregate()
        legacy.legs[0] = MissionLeg(
            id: legacy.legs[0].id,
            missionID: legacy.legs[0].missionID,
            ordinal: legacy.legs[0].ordinal,
            projectId: legacy.legs[0].projectId,
            baseRef: legacy.legs[0].baseRef,
            baseRemoteName: legacy.legs[0].baseRemoteName,
            branch: legacy.legs[0].branch,
            destinationPath: legacy.legs[0].destinationPath,
            worktreeId: legacy.legs[0].worktreeId,
            worktreeLineageID: legacy.legs[0].worktreeLineageID,
            agentId: legacy.legs[0].agentId,
            acpSessionId: legacy.legs[0].acpSessionId,
            initialPromptId: legacy.legs[0].initialPromptId,
            preparedInitialPrompt: "",
            pendingInitialPrompt: nil,
            reviewIdentity: legacy.legs[0].reviewIdentity,
            state: legacy.legs[0].state,
            setupCheckpoint: legacy.legs[0].setupCheckpoint,
            attentionReason: legacy.legs[0].attentionReason,
            readinessEvidence: legacy.legs[0].readinessEvidence,
            createdAt: legacy.legs[0].createdAt,
            updatedAt: legacy.legs[0].updatedAt
        )
        let fake = try MissionLifecycleFake(aggregate: legacy, worktreeAvailable: false)
        await fake.controller.load()

        await fake.controller.recordMissingWorktree(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.primaryLeg?.pendingInitialPrompt == MissionPromptBuilder.build(snapshot: aggregate.issue))
    }

    @Test func retryAndCompletionAreSerialized() async throws {
        var missing = Self.runningAggregate()
        missing.markPrimaryLegNeedsAttention(
            checkpoint: .running,
            reason: MissionReadinessEvaluator.missingWorktreeMessage
        )
        let gate = MissionWorktreeCreationGate()
        let fake = try MissionLifecycleFake(
            aggregate: missing,
            worktreeAvailable: false,
            createWorktree: { _ in await gate.create() }
        )
        await fake.controller.load()

        let retry = Task { await fake.controller.retry(Self.missionID) }
        await gate.waitUntilStarted()
        let completion = Task { await fake.controller.complete(Self.missionID) }
        await Task.yield()
        await gate.release()
        await retry.value
        await completion.value
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .completed)
    }

    @Test func removedProjectNeedsAttention() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .running,
            signal: .projectRemoved,
            observedAt: Date(timeIntervalSince1970: 101)
        ) == .needsAttention("The Mission project is no longer available."))
    }

    @Test func readyLegIsStickyAcrossRefreshFailure() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .ready,
            signal: .refreshUnavailable,
            observedAt: Date(timeIntervalSince1970: 101)
        ) == .unchanged(reviewIdentity: nil))
    }

    @Test func readyLegIgnoresMissingArtifactSignals() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .ready,
            signal: .worktreeMissing,
            observedAt: Date(timeIntervalSince1970: 101)
        ) == .unchanged(reviewIdentity: nil))
    }

    @Test func reviewIsLinkedBeforeItMerges() async throws {
        let fake = try MissionLifecycleFake()
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .open)
        )
        let linked = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(linked.mission.state == .running)
        #expect(linked.primaryLeg?.reviewIdentity == Self.reviewIdentity)
        #expect(linked.events.last?.kind == .reviewLinked)

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .merged)
        )
        let ready = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(ready.mission.state == .readyToComplete)
        #expect(ready.primaryLeg?.reviewIdentity == Self.reviewIdentity)
        #expect(ready.events.last?.kind == .ready)
    }

    @Test func liveReviewIgnoresReviewFromAnotherRepository() async throws {
        let fake = try MissionLifecycleFake()
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .merged, repository: "other")
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == nil)
    }

    @Test func liveReviewMatchesLinkedIdentityIgnoringRepositoryCase() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let fake = try MissionLifecycleFake(aggregate: linked)
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .merged, owner: "Acme", repository: "Alas")
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func firstDiscoveredReviewIdentityRemainsLinked() async throws {
        let linkedReview = try #require(Self.reviewSnapshot(state: .open).reviewRequest)
        let fake = try MissionLifecycleFake(
            linkedReviewRequest: { identity, _, _ in
                identity == Self.reviewIdentity ? linkedReview : nil
            }
        )
        await fake.controller.load()
        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .open)
        )

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .merged, number: 92)
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
        #expect(aggregate.mission.state == .running)
    }

    @Test func closedLinkedReviewCanBeReplacedByANewerReview() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let closedLinkedReview = try #require(Self.reviewSnapshot(state: .closed).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            linkedReviewRequest: { identity, _, _ in
                identity == Self.reviewIdentity ? closedLinkedReview : nil
            }
        )
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .merged, number: 92)
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func liveReviewReplacesAnUnavailableLinkedReview() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            linkedReviewRequest: { _, _, _ in nil }
        )
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .merged, number: 92)
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func retargetedOpenReviewCanBeReplacedByAVisibleOpenReview() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let retargeted = try #require(Self.reviewSnapshot(state: .open, baseBranch: "release").reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            linkedReviewRequest: { identity, _, _ in
                identity == Self.reviewIdentity ? retargeted : nil
            }
        )
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .open, number: 92)
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func staleOpenReviewCanBeReplacedByAVisibleOpenReviewAtTheCurrentHead() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let stale = try #require(Self.reviewSnapshot(state: .open, headSHA: "historical123").reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            linkedReviewRequest: { identity, _, _ in
                identity == Self.reviewIdentity ? stale : nil
            }
        )
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .open, number: 92)
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func mergedLinkedReviewMustMatchTheCurrentHeadCommit() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let staleReview = try #require(Self.reviewSnapshot(
            state: .merged,
            headSHA: "reviewed123"
        ).reviewRequest)
        let current = Self.reviewSnapshot(state: .open, headSHA: "current456")
        let snapshot = ReviewLoopSnapshot(
            local: current.local,
            remote: current.remote,
            reviewRequest: staleReview,
            providerAvailable: current.providerAvailable,
            providerAuthenticated: current.providerAuthenticated,
            providerCapabilities: current.providerCapabilities,
            errorMessage: current.errorMessage
        )
        let fake = try MissionLifecycleFake(aggregate: linked)
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: snapshot
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func liveReviewIgnoresAReplacementWorktreeOnAnotherBranch() async throws {
        let fake = try MissionLifecycleFake(worktreeBranch: "unrelated-branch")
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .merged)
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == nil)
    }

    @Test func liveReviewIgnoresAReplacementWorktreeWithTheSameBranch() async throws {
        var running = Self.runningAggregate()
        running.legs[0].worktreeLineageID = "original-lineage"
        let fake = try MissionLifecycleFake(
            aggregate: running,
            worktreeLineageID: "replacement-lineage"
        )
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .merged)
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == nil)
    }

    @Test func liveReviewIgnoresASnapshotFromAnotherBase() async throws {
        let fake = try MissionLifecycleFake()
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "release",
            snapshot: Self.reviewSnapshot(state: .merged)
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == nil)
    }

    @Test func liveReviewIgnoresASnapshotCapturedFromAnotherBranch() async throws {
        let fake = try MissionLifecycleFake()
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .merged, branch: "unrelated-branch")
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == nil)
    }

    @Test func liveReviewRevalidatesTheMergedCommitAgainstTheCurrentBranchTip() async throws {
        let fake = try MissionLifecycleFake(branchTip: { _, _ in "newer456" })
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .merged, headSHA: "abc123")
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == nil)
    }

    @Test func archiveIgnoresAReplacementWorktreeOnAnotherBranch() async throws {
        let fake = try MissionLifecycleFake(
            worktreeBranch: "unrelated-branch",
            worktreeArchived: { _, _ in true }
        )
        await fake.controller.load()

        await fake.controller.recordArchive(worktreeId: "worktree-1")
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.events.last?.kind != .ready)
    }

    @Test func archiveIgnoresAReplacementWorktreeWithTheSameBranch() async throws {
        var running = Self.runningAggregate()
        running.legs[0].worktreeLineageID = "original-lineage"
        let fake = try MissionLifecycleFake(
            aggregate: running,
            worktreeLineageID: "replacement-lineage",
            worktreeArchived: { _, _ in true }
        )
        await fake.controller.load()

        await fake.controller.recordArchive(worktreeId: "worktree-1")
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.events.last?.kind != .ready)
    }

    @Test func archiveSignalIsIgnoredAfterTheWorktreeIsRestored() async throws {
        let fake = try MissionLifecycleFake(worktreeArchived: { _, _ in false })
        await fake.controller.load()

        await fake.controller.recordArchive(worktreeId: "worktree-1")
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.events.last?.kind != .ready)
    }

    @Test func archiveStateIsRecheckedInsideTheLifecycleMutation() async throws {
        var checks = 0
        let fake = try MissionLifecycleFake(worktreeArchived: { _, _ in
            checks += 1
            return checks == 1
        })
        await fake.controller.load()

        await fake.controller.recordArchive(worktreeId: "worktree-1")
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(checks == 2)
        #expect(aggregate.mission.state == .running)
        #expect(aggregate.events.last?.kind != .ready)
    }

    @Test func linkedReviewIsRefreshedAfterItLeavesTheOpenReviewSnapshot() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let openSnapshot = Self.reviewSnapshot(state: .open)
        let missingOpenReview = ReviewLoopSnapshot(
            local: openSnapshot.local,
            remote: openSnapshot.remote,
            reviewRequest: nil,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .readOnly,
            errorMessage: nil
        )
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            linkedReviewRequest: { identity, projectID, baseRef in
                guard identity == Self.reviewIdentity,
                      projectID == "project-1",
                      baseRef == "main"
                else { return nil }
                return Self.reviewSnapshot(state: .merged).reviewRequest
            }
        )
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: missingOpenReview
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func linkedReviewIsRefreshedWhenAnotherReviewIsVisible() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let unrelatedVisibleReview = Self.reviewSnapshot(state: .open, number: 92)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            linkedReviewRequest: { identity, projectID, _ in
                guard identity == Self.reviewIdentity, projectID == "project-1" else { return nil }
                return Self.reviewSnapshot(state: .merged).reviewRequest
            }
        )
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: unrelatedVisibleReview
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func linkedReviewRefreshRejectsARetargetedReview() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let retargeted = try #require(Self.reviewSnapshot(
            state: .merged,
            baseBranch: "release"
        ).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            linkedReviewRequest: { _, _, _ in retargeted }
        )
        await fake.controller.load()

        await fake.controller.refreshLinkedReview(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func linkedReviewRefreshAcceptsPersistedBaseAfterRemoteRename() async throws {
        var linked = Self.runningAggregate(
            baseRef: "upstream/main",
            baseRemoteName: "upstream"
        )
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let merged = try #require(Self.reviewSnapshot(
            state: .merged,
            remoteName: "canonical"
        ).reviewRequest)
        var requestedBaseBranch: String?
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            linkedReviewRequest: { _, _, baseBranch in
                requestedBaseBranch = baseBranch
                return merged
            },
            branchTip: { _, _ in "abc123" }
        )
        await fake.controller.load()

        await fake.controller.refreshLinkedReview(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
        #expect(requestedBaseBranch == "main")
    }

    @Test func legacyBaseAliasIsResolvedBeforeReviewRefresh() async throws {
        var linked = Self.runningAggregate(
            baseRef: "upstream/main",
            baseRemoteName: nil
        )
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let merged = try #require(Self.reviewSnapshot(
            state: .merged,
            remoteName: "canonical"
        ).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            linkedReviewRequest: { _, _, _ in merged },
            branchTip: { _, _ in "abc123" }
        )
        await fake.controller.load()

        await fake.controller.resolveLegacyBaseRemoteNames { projectID, baseRef in
            #expect(projectID == "project-1")
            #expect(baseRef == "upstream/main")
            return "upstream"
        }
        await fake.controller.refreshLinkedReview(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.primaryLeg?.baseRemoteName == "upstream")
        #expect(aggregate.mission.state == .readyToComplete)
    }

    @Test func linkedReviewRefreshRejectsRetargetedSlashContainingBase() async throws {
        var linked = Self.runningAggregate()
        let originalLeg = linked.legs[0]
        linked.legs[0] = MissionLeg(
            id: originalLeg.id,
            missionID: originalLeg.missionID,
            ordinal: originalLeg.ordinal,
            projectId: originalLeg.projectId,
            baseRef: "release/1.0",
            branch: originalLeg.branch,
            destinationPath: originalLeg.destinationPath,
            worktreeId: originalLeg.worktreeId,
            agentId: originalLeg.agentId,
            acpSessionId: originalLeg.acpSessionId,
            initialPromptId: originalLeg.initialPromptId,
            pendingInitialPrompt: originalLeg.pendingInitialPrompt,
            reviewIdentity: Self.reviewIdentity
        )
        let retargeted = try #require(Self.reviewSnapshot(
            state: .merged,
            baseBranch: "1.0",
            remoteName: "release"
        ).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            linkedReviewRequest: { _, _, _ in retargeted },
            branchTip: { _, _ in "abc123" }
        )
        await fake.controller.load()

        await fake.controller.refreshLinkedReview(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func linkedMergedReviewMustMatchThePersistedBranchTip() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let staleMerged = try #require(Self.reviewSnapshot(
            state: .merged,
            headSHA: "reviewed123"
        ).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            linkedReviewRequest: { _, _, _ in staleMerged },
            branchTip: { _, _ in "current456" }
        )
        await fake.controller.load()

        await fake.controller.refreshLinkedReview(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func sourceIssueStateDoesNotChangeMissionReadiness() async throws {
        let refreshed = MissionFixtures.issue(title: "Fresh issue title", capturedAt: 250)
        var closed = refreshed
        closed = MissionIssueSnapshot(
            identity: closed.identity,
            canonicalURL: closed.canonicalURL,
            title: closed.title,
            body: closed.body,
            state: .closed,
            labels: closed.labels,
            assignees: closed.assignees,
            providerUpdatedAt: closed.providerUpdatedAt,
            capturedAt: closed.capturedAt,
            refreshError: nil
        )
        let fake = try MissionLifecycleFake(issueRefresh: { _, _ in closed })
        await fake.controller.load()

        await fake.controller.refreshIssue(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.issue == closed)
        #expect(aggregate.mission.state == .running)
        #expect(fake.notifications.last?.issue.title == "Fresh issue title")
    }

    @Test func repositoryRenamePublishesEveryMigratedDuplicateMission() async throws {
        var first = MissionFixtures.creatingMission(id: "mission-1")
        first.mission.state = .running
        first.mission.setupCheckpoint = .running
        first.legs[0].worktreeId = "worktree-1"
        first.legs[0].worktreeLineageID = "lineage-1"
        first.legs[0].pendingInitialPrompt = nil
        var second = MissionFixtures.creatingMission(id: "mission-2")
        second.mission.state = .running
        second.mission.setupCheckpoint = .running
        second.legs[0].worktreeId = "worktree-2"
        second.legs[0].worktreeLineageID = "lineage-2"
        second.legs[0].pendingInitialPrompt = nil
        let renamed = MissionIssueSnapshot(
            identity: .init(
                provider: first.issue.identity.provider,
                host: first.issue.identity.host,
                repositorySlug: "acquired/renamed-alas",
                number: first.issue.identity.number
            ),
            canonicalURL: URL(string: "https://github.com/acquired/renamed-alas/issues/42")!,
            title: "Fresh after rename",
            body: first.issue.body,
            state: first.issue.state,
            labels: first.issue.labels,
            assignees: first.issue.assignees,
            providerUpdatedAt: first.issue.providerUpdatedAt,
            capturedAt: Date(timeIntervalSince1970: 250),
            refreshError: nil
        )
        let fake = try MissionLifecycleFake(
            aggregate: first,
            additionalAggregates: [second],
            issueRefresh: { _, _ in renamed }
        )
        await fake.controller.load()

        await fake.controller.refreshIssue(first.mission.id)

        #expect(fake.controller.aggregate(id: first.mission.id)?.issue.identity == renamed.identity)
        #expect(fake.controller.aggregate(id: second.mission.id)?.issue.identity == renamed.identity)
        #expect(fake.notifications.contains { $0.mission.id == second.mission.id && $0.issue.identity == renamed.identity })
    }

    @Test func providerRefreshFailureRetainsSnapshotAndPersistsError() async throws {
        let failure = CodeHostProviderError.unauthenticated("github.com")
        let fake = try MissionLifecycleFake(issueRefresh: { _, _ in throw failure })
        await fake.controller.load()
        let before = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        await fake.controller.refreshIssue(Self.missionID)
        let after = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(fake.issueRefreshCalls == [IssueRefreshCall(
            identity: before.issue.identity,
            projectID: "project-1"
        )])
        #expect(after.issue.identity == before.issue.identity)
        #expect(after.issue.canonicalURL == before.issue.canonicalURL)
        #expect(after.issue.title == before.issue.title)
        #expect(after.issue.body == before.issue.body)
        #expect(after.issue.state == before.issue.state)
        #expect(after.issue.labels == before.issue.labels)
        #expect(after.issue.assignees == before.issue.assignees)
        #expect(after.issue.providerUpdatedAt == before.issue.providerUpdatedAt)
        #expect(after.issue.capturedAt == before.issue.capturedAt)
        #expect(after.issue.refreshError == "Authentication is required for github.com.")
        #expect(after.mission.state == .running)
    }

    @Test func lateRefreshFailureCannotOverwriteANewerSuccess() async throws {
        let race = RefreshIssueRace(success: MissionFixtures.issue(
            title: "Newer issue title",
            capturedAt: 500
        ))
        let fake = try MissionLifecycleFake(issueRefresh: { _, _ in
            try await race.refresh()
        })
        await fake.controller.load()

        let slowFailure = Task { await fake.controller.refreshIssue(Self.missionID) }
        await race.waitForSlowFailureToStart()

        await fake.controller.refreshIssue(Self.missionID)
        await race.releaseSlowFailure()
        await slowFailure.value

        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.issue.title == "Newer issue title")
        #expect(aggregate.issue.capturedAt == Date(timeIntervalSince1970: 500))
        #expect(aggregate.issue.refreshError == nil)
    }

    @Test func startupRestoresAReappearedMissionWorktree() async throws {
        var missing = Self.runningAggregate()
        missing.markPrimaryLegNeedsAttention(
            checkpoint: .running,
            reason: MissionReadinessEvaluator.missingWorktreeMessage
        )
        missing.legs[0].worktreeLineageID = "lineage-1"
        let fake = try MissionLifecycleFake(aggregate: missing)
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .running)
        #expect(aggregate.mission.attentionReason == nil)
        #expect(aggregate.events.last?.kind == .retryStarted)
        #expect(aggregate.events.last?.message == "Mission worktree became available again.")
    }

    @Test func startupDiscoversReviewPastAReplacementMissionWorktree() async throws {
        var missing = Self.runningAggregate()
        missing.markPrimaryLegNeedsAttention(
            checkpoint: .running,
            reason: MissionReadinessEvaluator.missingWorktreeMessage
        )
        missing.legs[0].worktreeLineageID = "original-lineage"
        let replacementReview = try #require(Self.reviewSnapshot(state: .merged).reviewRequest)
        var discoveryCalls = 0
        let fake = try MissionLifecycleFake(
            aggregate: missing,
            worktreeLineageID: "replacement-lineage",
            discoverReviewRequest: { _, _, _, _, _, _ in
                discoveryCalls += 1
                return replacementReview
            }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.events.last?.kind != .retryStarted)
        #expect(discoveryCalls == 1)
    }

    @Test func reappearedWorktreeResumesPendingAgentSetup() async throws {
        var missing = Self.runningAggregate()
        missing.markPrimaryLegNeedsAttention(
            checkpoint: .running,
            reason: MissionReadinessEvaluator.missingWorktreeMessage
        )
        missing.legs[0].worktreeLineageID = "lineage-1"
        missing.legs[0].pendingInitialPrompt = "Fix the issue."
        let fake = try MissionLifecycleFake(aggregate: missing)
        await fake.controller.load()

        await fake.controller.recordAvailableWorktree(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(fake.externalOperations == ["startACP"])
        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .startingAgent)
    }

    @Test func reappearedWorktreeDoesNotMutateACompletedMission() async throws {
        var missing = Self.runningAggregate()
        missing.markPrimaryLegNeedsAttention(
            checkpoint: .running,
            reason: MissionReadinessEvaluator.missingWorktreeMessage
        )
        let fake = try MissionLifecycleFake(aggregate: missing)
        await fake.controller.load()
        await fake.controller.complete(Self.missionID)
        let completed = try #require(try await fake.persistence.aggregate(id: Self.missionID))
        let eventCount = completed.events.count

        await fake.controller.recordAvailableWorktree(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .completed)
        #expect(aggregate.primaryLeg?.state == .needsAttention)
        #expect(aggregate.primaryLeg?.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
        #expect(aggregate.events.count == eventCount)
        #expect(fake.externalOperations.isEmpty)
    }

    @Test func startupRefreshesAMergedLinkedReviewWithoutAWorktree() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            worktreeAvailable: false,
            linkedReviewRequest: { identity, projectID, _ in
                guard identity == Self.reviewIdentity, projectID == "project-1" else { return nil }
                return Self.reviewSnapshot(state: .merged).reviewRequest
            }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func startupRecognizesCurrentMergedReviewWithoutPolling() async throws {
        let snapshot = Self.reviewSnapshot(state: .merged)
        let fake = try MissionLifecycleFake(
            projectExists: { $0 == "project-1" },
            worktreeArchived: { _, _ in false },
            reviewSnapshot: { worktreeID, baseRef in
                worktreeID == "worktree-1" && baseRef == "origin/main" ? snapshot : nil
            }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
        #expect(fake.issueRefreshCalls.isEmpty)
    }

    @Test func startupDiscoversAMergedReviewBeforeItsIdentityWasLinked() async throws {
        let request = try #require(Self.reviewSnapshot(state: .merged).reviewRequest)
        let currentSnapshot = Self.reviewSnapshotWithoutRequest(headOwner: "acme-fork")
        let fake = try MissionLifecycleFake(
            reviewSnapshot: { _, _ in nil },
            startupReviewSnapshot: { _, _ in currentSnapshot },
            discoverReviewRequest: { projectID, issueIdentity, branch, baseRef, headSHA, headOwner in
                #expect(projectID == "project-1")
                #expect(issueIdentity == MissionFixtures.issue().identity)
                #expect(branch == "fix/parser-crash")
                #expect(baseRef == "origin/main")
                #expect(headSHA == "abc123")
                #expect(headOwner == "acme-fork")
                return request
            },
            branchOwner: { _, _, _, _ in "acme-fork" }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func startupPrefersEffectivePushOwnerOverSnapshotTrackingOwner() async throws {
        let request = try #require(Self.reviewSnapshot(state: .merged).reviewRequest)
        let trackingSnapshot = Self.reviewSnapshotWithoutRequest(headOwner: "acme")
        let fake = try MissionLifecycleFake(
            reviewSnapshot: { _, _ in trackingSnapshot },
            discoverReviewRequest: { _, _, _, _, _, headOwner in
                #expect(headOwner == "acme-fork")
                return request
            },
            branchOwner: { _, _, _, _ in "acme-fork" }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func startupDiscoversAMergedReviewAlongsideMatchingOpenReview() async throws {
        let openSnapshot = Self.reviewSnapshot(state: .open)
        let merged = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            reviewSnapshot: { _, _ in nil },
            startupReviewSnapshot: { _, _ in openSnapshot },
            discoverReviewRequest: { _, _, _, _, _, _ in merged }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func startupDiscoversAMergedReplacementForAClosedLinkedReview() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let closed = try #require(Self.reviewSnapshot(state: .closed, baseBranch: "release").reviewRequest)
        let replacement = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            startupReviewSnapshot: { _, _ in Self.reviewSnapshotWithoutRequest() },
            discoverReviewRequest: { _, _, _, _, _, _ in replacement },
            linkedReviewRequest: { identity, _, _ in
                identity == Self.reviewIdentity ? closed : nil
            }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func startupDiscoversAMergedReviewWhenTheWorktreeIsMissing() async throws {
        let request = try #require(Self.reviewSnapshot(state: .merged).reviewRequest)
        let fake = try MissionLifecycleFake(
            worktreeAvailable: false,
            discoverReviewRequest: { projectID, issueIdentity, branch, baseRef, headSHA, headOwner in
                #expect(projectID == "project-1")
                #expect(issueIdentity == MissionFixtures.issue().identity)
                #expect(branch == "fix/parser-crash")
                #expect(baseRef == "origin/main")
                #expect(headSHA == "abc123")
                #expect(headOwner == "acme")
                return request
            },
            branchTip: { projectID, branch in
                #expect(projectID == "project-1")
                #expect(branch == "fix/parser-crash")
                return "abc123"
            }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func startupDiscoversMergedReviewAlongsideOpenReviewWhenWorktreeIsMissing() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let open = try #require(Self.reviewSnapshot(state: .open).reviewRequest)
        let merged = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            worktreeAvailable: false,
            discoverReviewRequest: { _, _, _, _, _, _ in merged },
            linkedReviewRequest: { _, _, _ in open },
            branchTip: { _, _ in "abc123" }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func manualRefreshDiscoversAMergedReviewWhenTheWorktreeIsMissing() async throws {
        let request = try #require(Self.reviewSnapshot(state: .merged).reviewRequest)
        let fake = try MissionLifecycleFake(
            worktreeAvailable: false,
            discoverReviewRequest: { _, _, _, _, headSHA, headOwner in
                #expect(headSHA == "abc123")
                #expect(headOwner == "acme-fork")
                return request
            },
            branchTip: { _, _ in "abc123" },
            branchOwner: { _, _, _, _ in "acme-fork" }
        )
        await fake.controller.load()

        await fake.controller.refreshReviewWithoutWorktree(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func manualRefreshDiscoversMergedReviewAlongsideOpenReviewWhenWorktreeIsMissing() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let open = try #require(Self.reviewSnapshot(state: .open).reviewRequest)
        let merged = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            worktreeAvailable: false,
            discoverReviewRequest: { _, _, _, _, _, _ in merged },
            linkedReviewRequest: { _, _, _ in open },
            branchTip: { _, _ in "abc123" }
        )
        await fake.controller.load()

        await fake.controller.refreshReviewWithoutWorktree(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func worktreeRemovalRefreshDiscoversMergedReviewBeforeBranchDeletion() async throws {
        let request = try #require(Self.reviewSnapshot(state: .merged).reviewRequest)
        let fake = try MissionLifecycleFake(
            discoverReviewRequest: { _, _, _, _, _, headOwner in
                #expect(headOwner == "acme-fork")
                return request
            },
            branchTip: { _, _ in "abc123" },
            branchOwner: { _, _, _, _ in "acme-fork" }
        )
        await fake.controller.load()

        let canDeleteBranch = await fake.controller.refreshReviewBeforeWorktreeRemoval("worktree-1")
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(canDeleteBranch)
        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func worktreeRemovalRefreshDiscoversMergedReviewAlongsideOpenReview() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let open = try #require(Self.reviewSnapshot(state: .open).reviewRequest)
        let merged = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            discoverReviewRequest: { _, _, _, _, _, _ in merged },
            linkedReviewRequest: { _, _, _ in open },
            branchTip: { _, _ in "abc123" }
        )
        await fake.controller.load()

        let canDeleteBranch = await fake.controller.refreshReviewBeforeWorktreeRemoval("worktree-1")
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(canDeleteBranch)
        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func worktreeRemovalRefreshRetainsBranchWhenReviewDiscoveryIsInconclusive() async throws {
        let fake = try MissionLifecycleFake(
            discoverReviewRequest: { _, _, _, _, _, _ in nil },
            branchTip: { _, _ in "abc123" }
        )
        await fake.controller.load()

        let canDeleteBranch = await fake.controller.refreshReviewBeforeWorktreeRemoval("worktree-1")
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(!canDeleteBranch)
        #expect(aggregate.mission.state == .running)
    }

    @Test func manualRefreshDiscoversAMergedReplacementWhenTheWorktreeIsMissing() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let closed = try #require(Self.reviewSnapshot(state: .closed, baseBranch: "release").reviewRequest)
        let replacement = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            worktreeAvailable: false,
            discoverReviewRequest: { _, _, _, _, _, _ in replacement },
            linkedReviewRequest: { identity, _, _ in
                identity == Self.reviewIdentity ? closed : nil
            },
            branchTip: { _, _ in "abc123" }
        )
        await fake.controller.load()

        await fake.controller.refreshReviewWithoutWorktree(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func missingWorktreeRefreshReplacesAnUnavailableLinkedReview() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let replacement = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            worktreeAvailable: false,
            discoverReviewRequest: { _, _, _, _, _, _ in replacement },
            linkedReviewRequest: { _, _, _ in nil },
            branchTip: { _, _ in "abc123" }
        )
        await fake.controller.load()

        await fake.controller.refreshReviewWithoutWorktree(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func missingWorktreeRefreshMatchesLinkedIdentityIgnoringRepositoryCase() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let merged = try #require(Self.reviewSnapshot(
            state: .merged,
            owner: "Acme",
            repository: "Alas"
        ).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            worktreeAvailable: false,
            linkedReviewRequest: { _, _, _ in merged },
            branchTip: { _, _ in "abc123" }
        )
        await fake.controller.load()

        await fake.controller.refreshReviewWithoutWorktree(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func manualRefreshDiscoversAMergedReplacementForARetargetedOpenReview() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let retargeted = try #require(Self.reviewSnapshot(state: .open, baseBranch: "release").reviewRequest)
        let replacement = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            worktreeAvailable: false,
            discoverReviewRequest: { _, _, _, _, _, _ in replacement },
            linkedReviewRequest: { identity, _, _ in
                identity == Self.reviewIdentity ? retargeted : nil
            },
            branchTip: { _, _ in "abc123" }
        )
        await fake.controller.load()

        await fake.controller.refreshReviewWithoutWorktree(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func liveRefreshDiscoversAMergedReplacementForARetargetedOpenReview() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let retargetedSnapshot = Self.reviewSnapshot(state: .open, baseBranch: "release")
        let retargeted = try #require(retargetedSnapshot.reviewRequest)
        let replacement = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            discoverReviewRequest: { _, _, _, _, _, _ in replacement },
            linkedReviewRequest: { identity, _, _ in
                identity == Self.reviewIdentity ? retargeted : nil
            }
        )
        await fake.controller.load()

        await fake.controller.discoverMergedReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: retargetedSnapshot
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func liveDiscoveryIgnoresAReplacementWorktreeWithTheSameBranch() async throws {
        var running = Self.runningAggregate()
        running.legs[0].worktreeLineageID = "original-lineage"
        let replacementReview = try #require(Self.reviewSnapshot(state: .merged).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: running,
            worktreeLineageID: "replacement-lineage",
            discoverReviewRequest: { _, _, _, _, _, _ in replacementReview }
        )
        await fake.controller.load()

        await fake.controller.discoverMergedReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshotWithoutRequest(headOwner: "acme-fork")
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == nil)
    }

    @Test func liveRefreshReplacesAnUnavailableLinkedReview() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let replacement = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            discoverReviewRequest: { _, _, _, _, _, _ in replacement },
            linkedReviewRequest: { _, _, _ in nil }
        )
        await fake.controller.load()

        await fake.controller.discoverMergedReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshotWithoutRequest()
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func liveRefreshResolvesMissingHeadOwnerBeforeDiscovery() async throws {
        let merged = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            discoverReviewRequest: { _, _, _, _, _, headOwner in
                #expect(headOwner == "enterprise-fork")
                return merged
            },
            branchOwner: { projectID, branch, identity, baseRef in
                #expect(projectID == "project-1")
                #expect(branch == "fix/parser-crash")
                #expect(identity == MissionFixtures.issue().identity)
                #expect(baseRef == "origin/main")
                return "enterprise-fork"
            }
        )
        await fake.controller.load()

        await fake.controller.discoverMergedReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshotWithoutRequest()
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func liveRefreshSkipsDiscoveryWhenHeadOwnerCannotBeResolved() async throws {
        var discoveryCalls = 0
        let merged = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            discoverReviewRequest: { _, _, _, _, _, _ in
                discoveryCalls += 1
                return merged
            },
            branchOwner: { _, _, _, _ in nil }
        )
        await fake.controller.load()

        await fake.controller.discoverMergedReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshotWithoutRequest()
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(discoveryCalls == 0)
        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == nil)
    }

    @Test func liveRefreshDiscoversAMergedReviewAlongsideMatchingOpenReview() async throws {
        let openSnapshot = Self.reviewSnapshot(state: .open)
        let merged = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            discoverReviewRequest: { _, _, _, _, _, _ in merged }
        )
        await fake.controller.load()

        await fake.controller.refreshReviewSnapshot(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: openSnapshot
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func liveRefreshMatchesLinkedIdentityIgnoringRepositoryCase() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let retargetedSnapshot = Self.reviewSnapshot(state: .open, baseBranch: "release")
        let retargeted = try #require(Self.reviewSnapshot(
            state: .open,
            baseBranch: "release",
            owner: "Acme",
            repository: "Alas"
        ).reviewRequest)
        let replacement = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            discoverReviewRequest: { _, _, _, _, _, _ in replacement },
            linkedReviewRequest: { _, _, _ in retargeted }
        )
        await fake.controller.load()

        await fake.controller.discoverMergedReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: retargetedSnapshot
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func missingWorktreeRefreshReplacesAnOpenReviewAtAStaleHead() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let stale = try #require(Self.reviewSnapshot(state: .open, headSHA: "historical123").reviewRequest)
        let replacement = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            worktreeAvailable: false,
            discoverReviewRequest: { _, _, _, _, _, _ in replacement },
            linkedReviewRequest: { identity, _, _ in
                identity == Self.reviewIdentity ? stale : nil
            },
            branchTip: { _, _ in "abc123" }
        )
        await fake.controller.load()

        await fake.controller.refreshReviewWithoutWorktree(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func liveRefreshReplacesAnOpenReviewAtAStaleHead() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        let staleSnapshot = Self.reviewSnapshot(
            state: .open,
            headSHA: "historical123",
            localHeadSHA: "abc123"
        )
        let stale = try #require(staleSnapshot.reviewRequest)
        let replacement = try #require(Self.reviewSnapshot(state: .merged, number: 92).reviewRequest)
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            discoverReviewRequest: { _, _, _, _, _, _ in replacement },
            linkedReviewRequest: { identity, _, _ in
                identity == Self.reviewIdentity ? stale : nil
            }
        )
        await fake.controller.load()

        await fake.controller.discoverMergedReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: staleSnapshot
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity?.number == 92)
    }

    @Test func snapshotRefreshDiscoversAMergedReviewThatIsNoLongerOpen() async throws {
        let replacement = try #require(Self.reviewSnapshot(state: .merged).reviewRequest)
        let fake = try MissionLifecycleFake(
            discoverReviewRequest: { _, _, _, _, _, _ in replacement }
        )
        await fake.controller.load()

        await fake.controller.refreshReviewSnapshot(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshotWithoutRequest()
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func manualRefreshDiscoversAMergedReviewBeforeItsIdentityWasLinked() async throws {
        let request = try #require(Self.reviewSnapshot(state: .merged).reviewRequest)
        let currentSnapshot = Self.reviewSnapshotWithoutRequest(headOwner: "acme-fork")
        let fake = try MissionLifecycleFake(
            discoverReviewRequest: { projectID, issueIdentity, branch, baseRef, headSHA, headOwner in
                #expect(projectID == "project-1")
                #expect(issueIdentity == MissionFixtures.issue().identity)
                #expect(branch == "fix/parser-crash")
                #expect(baseRef == "origin/main")
                #expect(headSHA == "abc123")
                #expect(headOwner == "acme-fork")
                return request
            },
            branchOwner: { _, _, _, _ in "acme-fork" }
        )
        await fake.controller.load()

        await fake.controller.discoverMergedReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: currentSnapshot
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func startupRejectsAHistoricalMergedReviewForAReusedBranch() async throws {
        let historical = try #require(Self.reviewSnapshot(
            state: .merged,
            headSHA: "historical123"
        ).reviewRequest)
        let fake = try MissionLifecycleFake(
            startupReviewSnapshot: { _, _ in Self.reviewSnapshotWithoutRequest() },
            discoverReviewRequest: { _, _, _, _, _, _ in historical }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == nil)
    }

    @Test func startupIgnoresAClosedUnmergedReviewWithoutLinkingIt() async throws {
        let closed = try #require(Self.reviewSnapshot(state: .closed).reviewRequest)
        let fake = try MissionLifecycleFake(
            startupReviewSnapshot: { _, _ in Self.reviewSnapshotWithoutRequest() },
            discoverReviewRequest: { _, _, _, _, _, _ in closed }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.reviewIdentity == nil)
    }

    @Test func mergedReviewWaitsForCreatingSetupToSettle() async throws {
        var creating = Self.runningAggregate()
        creating.mission.state = .creating
        creating.mission.setupCheckpoint = .running
        creating.legs[0].state = .creating
        creating.legs[0].setupCheckpoint = .running
        let fake = try MissionLifecycleFake(aggregate: creating)
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            baseRef: "origin/main",
            snapshot: Self.reviewSnapshot(state: .merged)
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.events.suffix(2).map(\.kind) == [.agentStarted, .ready])
    }

    @Test func archiveWaitsForCreatingSetupToSettle() async throws {
        var creating = Self.runningAggregate()
        creating.mission.state = .creating
        creating.mission.setupCheckpoint = .running
        creating.legs[0].state = .creating
        creating.legs[0].setupCheckpoint = .running
        let fake = try MissionLifecycleFake(
            aggregate: creating,
            worktreeArchived: { _, _ in true }
        )
        await fake.controller.load()

        await fake.controller.recordArchive(worktreeId: "worktree-1")
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.events.suffix(2).map(\.kind) == [.agentStarted, .ready])
        #expect(aggregate.events.last?.message == "Worktree archived in Alas.")
    }

    @Test func startupLoadsMergedReviewWhenNoRightPaneSnapshotExists() async throws {
        let snapshot = Self.reviewSnapshot(state: .merged)
        var requestedWorktreeIDs: [String] = []
        let fake = try MissionLifecycleFake(
            reviewSnapshot: { _, _ in nil },
            startupReviewSnapshot: { worktree, baseRef in
                requestedWorktreeIDs.append(worktree.id)
                #expect(baseRef == "origin/main")
                return snapshot
            }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(requestedWorktreeIDs == ["worktree-1"])
        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
    }

    @Test func startupMarksMissingWorktreeForAttentionWithoutTreatingItAsArchive() async throws {
        let fake = try MissionLifecycleFake(worktreeAvailable: false)
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.attentionReason == "The Mission worktree is no longer available.")
    }

    @Test func startupPreservesWorktreeCreationFailureWhenNoArtifactExists() async throws {
        var failed = MissionFixtures.creatingMission()
        failed.mission.state = .running
        failed.markPrimaryLegNeedsAttention(
            checkpoint: .creatingWorktree,
            reason: "branch exists retry later"
        )
        failed.legs[0].worktreeId = "worktree-1"
        let fake = try MissionLifecycleFake(aggregate: failed, worktreeAvailable: false)
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .creatingWorktree)
        #expect(aggregate.mission.attentionReason == "branch exists retry later")
    }

    @Test func startupResetsALaterCheckpointWhenItsWorktreeIsMissing() async throws {
        var failedAgent = Self.runningAggregate()
        failedAgent.markPrimaryLegNeedsAttention(
            checkpoint: .startingAgent,
            reason: "ACP setup failed."
        )
        let fake = try MissionLifecycleFake(aggregate: failedAgent, worktreeAvailable: false)
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .running)
        #expect(aggregate.mission.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
    }

    @Test func startupRejectsAWorktreeOnTheWrongBranch() async throws {
        let fake = try MissionLifecycleFake(worktreeBranch: "unrelated-branch")
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.attentionReason == "The Mission worktree is no longer available.")
    }

    @Test func startupResetsALaterCheckpointForAReplacementBranch() async throws {
        var failedAgent = Self.runningAggregate()
        failedAgent.markPrimaryLegNeedsAttention(
            checkpoint: .startingAgent,
            reason: "ACP setup failed."
        )
        let fake = try MissionLifecycleFake(
            aggregate: failedAgent,
            worktreeBranch: "unrelated-branch"
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .running)
        #expect(aggregate.mission.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
    }

    @Test func startupRefreshesLinkedReviewPastAReplacementWorktree() async throws {
        var linked = Self.runningAggregate()
        linked.legs[0].reviewIdentity = Self.reviewIdentity
        linked.legs[0].worktreeLineageID = "original-lineage"
        var linkedReviewCalls = 0
        let fake = try MissionLifecycleFake(
            aggregate: linked,
            worktreeLineageID: "replacement-lineage",
            linkedReviewRequest: { identity, projectID, _ in
                linkedReviewCalls += 1
                guard identity == Self.reviewIdentity, projectID == "project-1" else { return nil }
                return Self.reviewSnapshot(state: .merged).reviewRequest
            }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
        #expect(linkedReviewCalls == 1)
    }

    @Test func startupDoesNotArchiveAReplacementWorktreeOnTheWrongBranch() async throws {
        let fake = try MissionLifecycleFake(
            worktreeBranch: "unrelated-branch",
            worktreeArchived: { _, _ in true }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.attentionReason == "The Mission worktree is no longer available.")
    }

    @Test func startupPreservesRunningStateWhenWorktreeDiscoveryFailed() async throws {
        let fake = try MissionLifecycleFake(
            worktreeAvailable: false,
            worktreeDiscoverySucceeded: { _ in false }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.attentionReason == nil)
    }

    @Test func startupMarksRemovedProjectForAttention() async throws {
        let fake = try MissionLifecycleFake(projectExists: { _ in false })
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.attentionReason == "The Mission project is no longer available.")
    }

    @Test func completionChangesOnlyMissionPersistence() async throws {
        let fake = try MissionLifecycleFake()
        await fake.controller.load()

        await fake.controller.complete(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .completed)
        #expect(aggregate.mission.completedAt != nil)
        #expect(aggregate.events.last?.kind == .completed)
        #expect(fake.issueRefreshCalls.isEmpty)
        #expect(fake.externalOperations.isEmpty)
    }

    @Test func readinessSignalsDoNotMutateACompletedMission() async throws {
        let fake = try MissionLifecycleFake(worktreeAvailable: false)
        await fake.controller.load()
        await fake.controller.complete(Self.missionID)
        let completed = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        await fake.controller.recordMissingWorktree(Self.missionID)
        let unchanged = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(unchanged == completed)
    }

    @Test func completionPreservesOriginalLineageWhenOnlyAReplacementExists() async throws {
        var missing = Self.runningAggregate()
        missing.markPrimaryLegNeedsAttention(
            checkpoint: .running,
            reason: MissionReadinessEvaluator.missingWorktreeMessage
        )
        missing.legs[0].worktreeLineageID = "original-lineage"
        let fake = try MissionLifecycleFake(
            aggregate: missing,
            worktreeLineageID: "replacement-lineage"
        )
        await fake.controller.load()

        await fake.controller.complete(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .completed)
        #expect(aggregate.primaryLeg?.worktreeLineageID == "original-lineage")
    }

    @Test(arguments: [MissionState.needsAttention, .readyToComplete])
    func completionAcceptsOtherSettledStates(state: MissionState) async throws {
        var settled = Self.runningAggregate()
        settled.mission.state = state
        settled.mission.attentionReason = state == .needsAttention ? "Review setup." : nil
        if state == .needsAttention {
            settled.markPrimaryLegNeedsAttention(
                checkpoint: .running,
                reason: "Review setup."
            )
        }
        let fake = try MissionLifecycleFake(aggregate: settled)
        await fake.controller.load()

        await fake.controller.complete(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .completed)
        #expect(aggregate.mission.completedAt != nil)
        #expect(fake.issueRefreshCalls.isEmpty)
        #expect(fake.externalOperations.isEmpty)
    }

    @Test func completionRejectsAnActivelyCreatingMission() async throws {
        var creating = MissionFixtures.creatingMission()
        creating.legs[0].worktreeId = "worktree-1"
        let fake = try MissionLifecycleFake(aggregate: creating)
        await fake.controller.load()

        await fake.controller.complete(Self.missionID)
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .creating)
        #expect(aggregate.mission.completedAt == nil)
        #expect(aggregate.events.last?.kind == .created)
        #expect(fake.externalOperations.isEmpty)
    }

    fileprivate static func runningAggregate(
        baseRef: String = "origin/main",
        baseRemoteName: String? = "origin"
    ) -> MissionAggregate {
        var aggregate = MissionFixtures.creatingMission(
            baseRef: baseRef,
            baseRemoteName: baseRemoteName
        )
        aggregate.mission.state = .running
        aggregate.mission.setupCheckpoint = .running
        aggregate.legs[0].worktreeId = "worktree-1"
        aggregate.legs[0].acpSessionId = "session-1"
        aggregate.legs[0].pendingInitialPrompt = nil
        aggregate.legs[0].state = .running
        aggregate.legs[0].setupCheckpoint = .running
        aggregate.legs[0].attentionReason = nil
        return aggregate
    }

    private static func reviewSnapshot(
        state: ReviewRequestState,
        number: Int = 91,
        branch: String = "fix/parser-crash",
        headSHA: String = "abc123",
        localHeadSHA: String? = nil,
        headOwner: String? = nil,
        baseBranch: String = "main",
        owner: String = "acme",
        repository: String = "alas",
        remoteName: String = "origin"
    ) -> ReviewLoopSnapshot {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: owner,
            repository: repository,
            remoteName: remoteName,
            webURL: URL(string: "https://github.com/\(owner)/\(repository)")!
        )
        let request = ReviewRequest(
            remote: remote,
            number: number,
            title: "Mission review",
            url: remote.reviewRequestURL(number: number),
            state: state,
            isDraft: false,
            headRefName: branch,
            baseRefName: baseBranch,
            headSHA: headSHA,
            reviewDecision: .approved,
            mergeState: .clean,
            checks: [],
            threads: []
        )
        return ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: branch,
                headSHA: localHeadSHA ?? headSHA,
                baseBranch: "main",
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: 1,
                hasUpstream: true,
                headRemoteOwner: headOwner,
                needsPush: false
            ),
            remote: remote,
            reviewRequest: request,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .readOnly,
            errorMessage: nil
        )
    }

    private static func reviewSnapshotWithoutRequest(headOwner: String? = nil) -> ReviewLoopSnapshot {
        let snapshot = reviewSnapshot(state: .open, headOwner: headOwner)
        return ReviewLoopSnapshot(
            local: snapshot.local,
            remote: snapshot.remote,
            reviewRequest: nil,
            providerAvailable: snapshot.providerAvailable,
            providerAuthenticated: snapshot.providerAuthenticated,
            providerCapabilities: snapshot.providerCapabilities,
            errorMessage: snapshot.errorMessage
        )
    }
}

private struct IssueRefreshCall: Equatable {
    let identity: MissionIssueIdentity
    let projectID: String
}

private extension MissionAggregate {
    mutating func markPrimaryLegNeedsAttention(
        checkpoint: MissionSetupCheckpoint,
        reason: String
    ) {
        mission.state = .needsAttention
        mission.setupCheckpoint = checkpoint
        mission.attentionReason = reason
        guard let index = legs.firstIndex(where: { $0.id == mission.primaryLegID }) else { return }
        legs[index].state = .needsAttention
        legs[index].setupCheckpoint = checkpoint
        legs[index].attentionReason = reason
    }
}

@MainActor
private final class MissionLifecycleFake {
    let persistence: MissionPersistence
    let controller: MissionController
    private let recorder: MissionLifecycleRecorder

    var issueRefreshCalls: [IssueRefreshCall] { recorder.issueRefreshCalls }
    var externalOperations: [String] { recorder.externalOperations }
    var notifications: [MissionAggregate] { recorder.notifications }

    init(
        aggregate: MissionAggregate = MissionReadinessEvaluatorTests.runningAggregate(),
        additionalAggregates: [MissionAggregate] = [],
        worktreeAvailable: Bool = true,
        worktreeBranch: String = "fix/parser-crash",
        worktreeLineageID: String? = "lineage-1",
        issueRefresh: @escaping MissionIssueRefresh = { _, _ in
            throw CodeHostProviderError.malformedOutput("No issue refresh configured.")
        },
        projectExists: @escaping @MainActor (String) -> Bool = { _ in true },
        worktreeDiscoverySucceeded: @escaping @MainActor (String) -> Bool = { _ in true },
        worktreeArchived: @escaping @MainActor (String, String) -> Bool = { _, _ in false },
        reviewSnapshot: @escaping @MainActor (String, String) -> ReviewLoopSnapshot? = { _, _ in nil },
        startupReviewSnapshot: @escaping MissionStartupReviewSnapshot = { _, _ in nil },
        discoverReviewRequest: @escaping MissionReviewDiscovery = { _, _, _, _, _, _ in nil },
        linkedReviewRequest: @escaping MissionLinkedReviewRequest = { _, _, _ in nil },
        branchTip: @escaping MissionBranchTip = { _, _ in "abc123" },
        branchOwner: @escaping MissionBranchOwner = { _, _, identity, _ in
            identity.repositorySlug.split(separator: "/").dropLast().joined(separator: "/")
        },
        createWorktree: ((MissionLeg) async -> Result<Worktree, WorktreeCreationFailure>)? = nil
    ) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-lifecycle-\(UUID().uuidString).sqlite")
            .path
        let store = try MissionStore(path: path)
        var aggregate = aggregate
        if aggregate.mission.state != .completed,
           aggregate.primaryLeg?.worktreeId != nil,
           aggregate.primaryLeg?.worktreeLineageID == nil {
            aggregate.legs[0].worktreeLineageID = worktreeLineageID
        }
        try store.insert(aggregate)
        for additional in additionalAggregates {
            try store.insert(additional, allowDuplicate: true)
        }
        persistence = MissionPersistence(path: path)
        let recorder = MissionLifecycleRecorder()
        self.recorder = recorder

        var clock: TimeInterval = 1_000
        var id = 0
        controller = MissionController(
            environment: .init(
                persistence: persistence,
                now: {
                    clock += 1
                    return Date(timeIntervalSince1970: clock)
                },
                makeID: {
                    id += 1
                    return "lifecycle-event-\(id)"
                },
                worktreeAtDestination: { projectID, destinationPath in
                    guard worktreeAvailable,
                          projectID == "project-1",
                          destinationPath == "/tmp/alas-mission"
                    else { return nil }
                    return Worktree(
                        id: "worktree-1",
                        projectId: "project-1",
                        name: "fix/parser-crash",
                        branch: worktreeBranch,
                        path: URL(fileURLWithPath: "/tmp/alas-mission"),
                        status: .clean,
                        lastActivity: Date(timeIntervalSince1970: 100),
                        lineageID: worktreeLineageID
                    )
                },
                createWorktree: { leg in
                    recorder.externalOperations.append("createWorktree")
                    if let createWorktree {
                        return await createWorktree(leg)
                    }
                    return .failure(.init(message: "Unexpected worktree creation."))
                },
                startACP: { _, _ in
                    recorder.externalOperations.append("startACP")
                    return .failure(.init(message: "Unexpected ACP startup."))
                },
                notifyChanged: { recorder.notifications.append($0) }
            ),
            issueRefresh: { identity, projectID in
                recorder.issueRefreshCalls.append(.init(identity: identity, projectID: projectID))
                return try await issueRefresh(identity, projectID)
            },
            linkedReviewRequest: linkedReviewRequest,
            branchTip: branchTip,
            branchOwner: branchOwner,
            projectExists: projectExists,
            worktreeDiscoverySucceeded: worktreeDiscoverySucceeded,
            worktreeArchived: worktreeArchived,
            reviewSnapshot: reviewSnapshot,
            startupReviewSnapshot: startupReviewSnapshot,
            discoverReviewRequest: discoverReviewRequest
        )
    }
}

@MainActor
private final class MissionLifecycleRecorder {
    var issueRefreshCalls: [IssueRefreshCall] = []
    var externalOperations: [String] = []
    var notifications: [MissionAggregate] = []
}

@MainActor
private final class RefreshIssueRace {
    private let success: MissionIssueSnapshot
    private var invocationCount = 0
    private var slowFailureStarted = false
    private var slowFailureStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var slowFailureRelease: CheckedContinuation<Void, Never>?

    init(success: MissionIssueSnapshot) {
        self.success = success
    }

    func refresh() async throws -> MissionIssueSnapshot {
        invocationCount += 1
        guard invocationCount == 1 else { return success }

        slowFailureStarted = true
        let waiters = slowFailureStartWaiters
        slowFailureStartWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            slowFailureRelease = continuation
        }
        throw CodeHostProviderError.unauthenticated("github.com")
    }

    func waitForSlowFailureToStart() async {
        guard !slowFailureStarted else { return }
        await withCheckedContinuation { continuation in
            slowFailureStartWaiters.append(continuation)
        }
    }

    func releaseSlowFailure() {
        slowFailureRelease?.resume()
        slowFailureRelease = nil
    }
}

@MainActor
private final class MissionWorktreeCreationGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func create() async -> Result<Worktree, WorktreeCreationFailure> {
        started = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return .failure(.init(message: "Creation failed."))
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
