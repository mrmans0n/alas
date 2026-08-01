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

    @Test func mergedReviewMakesRunningMissionReady() {
        let decision = MissionReadinessEvaluator.evaluate(
            currentState: .running,
            signal: .review(state: .merged, identity: Self.reviewIdentity)
        )

        #expect(decision == .ready(
            reviewIdentity: Self.reviewIdentity,
            message: "PR #91 merged."
        ))
    }

    @Test func openReviewLinksWithoutMakingMissionReady() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .running,
            signal: .review(state: .open, identity: Self.reviewIdentity)
        ) == .unchanged(reviewIdentity: Self.reviewIdentity))
    }

    @Test func closedUnmergedReviewDoesNotMakeMissionReady() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .running,
            signal: .review(state: .closed, identity: Self.reviewIdentity)
        ) == .unchanged(reviewIdentity: Self.reviewIdentity))
    }

    @Test func explicitArchiveMakesRunningMissionReady() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .running,
            signal: .worktreeArchived
        ) == .ready(reviewIdentity: nil, message: "Worktree archived in Alas."))
    }

    @Test func externallyMissingWorktreeNeedsAttention() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .running,
            signal: .worktreeMissing
        ) == .needsAttention("The Mission worktree is no longer available."))
    }

    @Test func removedProjectNeedsAttention() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .running,
            signal: .projectRemoved
        ) == .needsAttention("The Mission project is no longer available."))
    }

    @Test func readyStateIsStickyAcrossRefreshFailure() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .readyToComplete,
            signal: .refreshUnavailable
        ) == .unchanged(reviewIdentity: nil))
    }

    @Test func readyAndCompletedStatesIgnoreMissingArtifactSignals() {
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .readyToComplete,
            signal: .worktreeMissing
        ) == .unchanged(reviewIdentity: nil))
        #expect(MissionReadinessEvaluator.evaluate(
            currentState: .completed,
            signal: .projectRemoved
        ) == .unchanged(reviewIdentity: nil))
    }

    @Test func reviewIsLinkedBeforeItMerges() async throws {
        let fake = try MissionLifecycleFake()
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            snapshot: Self.reviewSnapshot(state: .open)
        )
        let linked = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(linked.mission.state == .running)
        #expect(linked.primaryLeg?.reviewIdentity == Self.reviewIdentity)
        #expect(linked.events.last?.kind == .reviewLinked)

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            snapshot: Self.reviewSnapshot(state: .merged)
        )
        let ready = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(ready.mission.state == .readyToComplete)
        #expect(ready.primaryLeg?.reviewIdentity == Self.reviewIdentity)
        #expect(ready.events.last?.kind == .ready)
    }

    @Test func firstDiscoveredReviewIdentityRemainsLinked() async throws {
        let fake = try MissionLifecycleFake()
        await fake.controller.load()
        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            snapshot: Self.reviewSnapshot(state: .open)
        )

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            snapshot: Self.reviewSnapshot(state: .merged, number: 92)
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
        #expect(aggregate.mission.state == .running)
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
            linkedReviewRequest: { identity, worktreeID in
                guard identity == Self.reviewIdentity, worktreeID == "worktree-1" else { return nil }
                return Self.reviewSnapshot(state: .merged).reviewRequest
            }
        )
        await fake.controller.load()

        await fake.controller.observeReview(
            worktreeId: "worktree-1",
            snapshot: missingOpenReview
        )
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
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

    @Test func lateRefreshFailurePreservesNewerSuccessfulSnapshot() async throws {
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
        #expect(aggregate.issue.refreshError == "Authentication is required for github.com.")
    }

    @Test func startupRecognizesCurrentMergedReviewWithoutPolling() async throws {
        let snapshot = Self.reviewSnapshot(state: .merged)
        let fake = try MissionLifecycleFake(
            projectExists: { $0 == "project-1" },
            worktreeArchived: { _, _ in false },
            reviewSnapshot: { $0 == "worktree-1" ? snapshot : nil }
        )
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .readyToComplete)
        #expect(aggregate.primaryLeg?.reviewIdentity == Self.reviewIdentity)
        #expect(fake.issueRefreshCalls.isEmpty)
    }

    @Test func startupLoadsMergedReviewWhenNoRightPaneSnapshotExists() async throws {
        let snapshot = Self.reviewSnapshot(state: .merged)
        var requestedWorktreeIDs: [String] = []
        let fake = try MissionLifecycleFake(
            reviewSnapshot: { _ in nil },
            startupReviewSnapshot: { worktree in
                requestedWorktreeIDs.append(worktree.id)
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

        #expect(aggregate.mission.state == .needsAttention)
        #expect(aggregate.mission.attentionReason == "The Mission worktree is no longer available.")
    }

    @Test func startupMarksRemovedProjectForAttention() async throws {
        let fake = try MissionLifecycleFake(projectExists: { _ in false })
        await fake.controller.load()

        await fake.controller.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: Self.missionID))

        #expect(aggregate.mission.state == .needsAttention)
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

    @Test(arguments: [MissionState.needsAttention, .readyToComplete])
    func completionAcceptsOtherSettledStates(state: MissionState) async throws {
        var settled = Self.runningAggregate()
        settled.mission.state = state
        settled.mission.attentionReason = state == .needsAttention ? "Review setup." : nil
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

    fileprivate static func runningAggregate() -> MissionAggregate {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.mission.setupCheckpoint = .running
        aggregate.legs[0].worktreeId = "worktree-1"
        aggregate.legs[0].acpSessionId = "session-1"
        aggregate.legs[0].pendingInitialPrompt = nil
        return aggregate
    }

    private static func reviewSnapshot(
        state: ReviewRequestState,
        number: Int = 91
    ) -> ReviewLoopSnapshot {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "acme",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/acme/alas")!
        )
        let request = ReviewRequest(
            remote: remote,
            number: number,
            title: "Mission review",
            url: remote.reviewRequestURL(number: number),
            state: state,
            isDraft: false,
            headRefName: "fix/parser-crash",
            baseRefName: "main",
            headSHA: "abc123",
            reviewDecision: .approved,
            mergeState: .clean,
            checks: [],
            threads: []
        )
        return ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: "fix/parser-crash",
                headSHA: "abc123",
                baseBranch: "main",
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: 1,
                hasUpstream: true,
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
}

private struct IssueRefreshCall: Equatable {
    let identity: MissionIssueIdentity
    let projectID: String
}

@MainActor
private final class MissionLifecycleFake {
    let persistence: MissionPersistence
    let controller: MissionController
    private let recorder: MissionLifecycleRecorder

    var issueRefreshCalls: [IssueRefreshCall] { recorder.issueRefreshCalls }
    var externalOperations: [String] { recorder.externalOperations }

    init(
        aggregate: MissionAggregate = MissionReadinessEvaluatorTests.runningAggregate(),
        worktreeAvailable: Bool = true,
        issueRefresh: @escaping MissionIssueRefresh = { _, _ in
            throw CodeHostProviderError.malformedOutput("No issue refresh configured.")
        },
        projectExists: @escaping @MainActor (String) -> Bool = { _ in true },
        worktreeArchived: @escaping @MainActor (String, String) -> Bool = { _, _ in false },
        reviewSnapshot: @escaping @MainActor (String) -> ReviewLoopSnapshot? = { _ in nil },
        startupReviewSnapshot: @escaping @MainActor (Worktree) async -> ReviewLoopSnapshot? = { _ in nil },
        linkedReviewRequest: @escaping @MainActor (MissionReviewIdentity, String) async -> ReviewRequest? = { _, _ in nil }
    ) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-lifecycle-\(UUID().uuidString).sqlite")
            .path
        let store = try MissionStore(path: path)
        try store.insert(aggregate)
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
                        branch: "fix/parser-crash",
                        path: URL(fileURLWithPath: "/tmp/alas-mission"),
                        status: .clean,
                        lastActivity: Date(timeIntervalSince1970: 100)
                    )
                },
                createWorktree: { _ in
                    recorder.externalOperations.append("createWorktree")
                    return .failure(.init(message: "Unexpected worktree creation."))
                },
                startACP: { _, _ in
                    recorder.externalOperations.append("startACP")
                    return .failure(.init(message: "Unexpected ACP startup."))
                },
                notifyChanged: { _ in }
            ),
            issueRefresh: { identity, projectID in
                recorder.issueRefreshCalls.append(.init(identity: identity, projectID: projectID))
                return try await issueRefresh(identity, projectID)
            },
            linkedReviewRequest: linkedReviewRequest,
            projectExists: projectExists,
            worktreeArchived: worktreeArchived,
            reviewSnapshot: reviewSnapshot,
            startupReviewSnapshot: startupReviewSnapshot
        )
    }
}

@MainActor
private final class MissionLifecycleRecorder {
    var issueRefreshCalls: [IssueRefreshCall] = []
    var externalOperations: [String] = []
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
