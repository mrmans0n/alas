import Foundation
import Testing
@testable import Alas

@MainActor
struct CommitPublishWorkflowTests {
    @Test func normalNewRequestPublishesInOrder() async {
        let harness = WorkflowHarness()
        let workflow = harness.makeWorkflow()

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .review(harness.target))

        #expect(harness.calls == ["commit", "head", "remoteContainsCommit", "push", "lookupPR", "createPR"])
        #expect(harness.checkpointPhases == [.push, .createReviewRequest])
        #expect(harness.checkpoint == nil)
        #expect(workflow.activity == .idle)
        #expect(workflow.lastError == nil)
    }

    @Test func existingRequestCompletesWithoutCreatingAnotherRequest() async {
        let harness = WorkflowHarness()
        harness.reviewRequestExists = true
        let workflow = harness.makeWorkflow()

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .review(harness.target))

        #expect(harness.calls == ["commit", "head", "remoteContainsCommit", "push", "lookupPR"])
        #expect(harness.checkpoint == nil)
    }

    @Test func ggSyncsAfterCommit() async {
        let harness = WorkflowHarness()
        let workflow = harness.makeWorkflow()

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .gg)

        #expect(harness.calls == ["commit", "head", "sync"])
        #expect(harness.checkpointPhases == [.sync])
        #expect(harness.checkpoint == nil)
    }

    @Test func commitFailureDoesNotCheckpoint() async {
        let harness = WorkflowHarness()
        harness.createCommitError = WorkflowHarness.Failure.commit
        let workflow = harness.makeWorkflow()

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .review(harness.target))

        #expect(harness.calls == ["commit"])
        #expect(harness.checkpoint == nil)
        #expect(workflow.lastError != nil)
    }

    @Test func pushFailureRetainsPushCheckpoint() async {
        let harness = WorkflowHarness()
        harness.pushError = WorkflowHarness.Failure.push
        let workflow = harness.makeWorkflow()

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .review(harness.target))

        #expect(harness.calls == ["commit", "head", "remoteContainsCommit", "push"])
        #expect(harness.checkpoint?.nextPhase == .push)
    }

    @Test func lookupFailureAfterPushRetainsCreateRequestCheckpoint() async {
        let harness = WorkflowHarness()
        harness.lookupError = WorkflowHarness.Failure.lookup
        let workflow = harness.makeWorkflow()

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .review(harness.target))

        #expect(harness.calls == ["commit", "head", "remoteContainsCommit", "push", "lookupPR"])
        #expect(harness.checkpoint?.nextPhase == .createReviewRequest)
    }

    @Test func createFailureRetainsCreateRequestCheckpoint() async {
        let harness = WorkflowHarness()
        harness.createRequestError = WorkflowHarness.Failure.create
        let workflow = harness.makeWorkflow()

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .review(harness.target))

        #expect(harness.calls == ["commit", "head", "remoteContainsCommit", "push", "lookupPR", "createPR"])
        #expect(harness.checkpoint?.nextPhase == .createReviewRequest)
    }

    @Test func syncFailureRetainsSyncCheckpoint() async {
        let harness = WorkflowHarness()
        harness.syncError = WorkflowHarness.Failure.sync
        let workflow = harness.makeWorkflow()

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .gg)

        #expect(harness.calls == ["commit", "head", "sync"])
        #expect(harness.checkpoint?.nextPhase == .sync)
    }

    @Test func resumeNeverCreatesAnotherCommit() async {
        let harness = WorkflowHarness()
        let workflow = harness.makeWorkflow()

        await workflow.resume(harness.checkpoint(nextPhase: .push))

        #expect(harness.calls == ["head", "remoteContainsCommit", "push", "lookupPR", "createPR"])
    }

    @Test func headMismatchStopsBeforeRemoteOperations() async {
        let harness = WorkflowHarness()
        harness.headSHA = "different-sha"
        let workflow = harness.makeWorkflow()

        let checkpoint = harness.checkpoint(nextPhase: .push)
        harness.checkpoint = checkpoint

        await workflow.resume(checkpoint)

        #expect(harness.calls == ["head"])
        #expect(harness.checkpoint?.nextPhase == .push)
        #expect(workflow.lastError != nil)
    }

    @Test func remoteContainmentSkipsPushEvenWithoutAnUpstreamBranch() async {
        let harness = WorkflowHarness()
        harness.remoteContainsCommit = true
        let noUpstreamTarget = harness.targetWithoutUpstream
        let workflow = harness.makeWorkflow()

        await workflow.resume(harness.checkpoint(target: noUpstreamTarget, nextPhase: .push))

        #expect(harness.calls == ["head", "remoteContainsCommit", "lookupPR", "createPR"])
    }

    @Test func freshLookupSkipsCreateWhenRequestNowExists() async {
        let harness = WorkflowHarness()
        harness.reviewRequestExists = true
        let workflow = harness.makeWorkflow()

        await workflow.resume(harness.checkpoint(nextPhase: .createReviewRequest))

        #expect(harness.calls == ["head", "lookupPR"])
    }

    @Test func completionClearsCheckpointBeforeRefreshing() async {
        let harness = WorkflowHarness()
        harness.refreshChecksCheckpoint = true
        let workflow = harness.makeWorkflow()
        let checkpoint = harness.checkpoint(nextPhase: .createReviewRequest)
        harness.checkpoint = checkpoint

        await workflow.resume(checkpoint)

        #expect(harness.checkpointWasClearedBeforeRefresh)
    }
}

@MainActor
private final class WorkflowHarness {
    enum Failure: Error {
        case commit
        case push
        case lookup
        case create
        case sync
    }

    var calls: [String] = []
    var checkpoint: CommitPublishCheckpoint?
    var checkpointPhases: [CommitPublishPhase] = []
    var headSHA = "commit-sha"
    var remoteContainsCommit = false
    var reviewRequestExists = false
    var createCommitError: Error?
    var pushError: Error?
    var lookupError: Error?
    var createRequestError: Error?
    var syncError: Error?
    var refreshChecksCheckpoint = false
    var checkpointWasClearedBeforeRefresh = false

    let target = CommitPublishReviewTarget(
        provider: .github,
        host: "github.com",
        owner: "owner",
        repository: "repository",
        repositorySlug: "owner/repository",
        remoteName: "origin",
        webURL: URL(string: "https://github.com/owner/repository")!,
        branch: "feature",
        upstreamBranch: "origin/feature",
        headOwner: "owner",
        baseBranch: "main",
        reviewRequestExisted: false,
        createAsDraft: false
    )

    let targetWithoutUpstream = CommitPublishReviewTarget(
        provider: .github,
        host: "github.com",
        owner: "owner",
        repository: "repository",
        repositorySlug: "owner/repository",
        remoteName: "origin",
        webURL: URL(string: "https://github.com/owner/repository")!,
        branch: "feature",
        upstreamBranch: nil,
        headOwner: "owner",
        baseBranch: "main",
        reviewRequestExisted: false,
        createAsDraft: false
    )

    func makeWorkflow() -> CommitPublishWorkflow {
        CommitPublishWorkflow(
            operations: CommitPublishOperations(
                createCommit: { [unowned self] _, _, _ in
                    calls.append("commit")
                    if let createCommitError { throw createCommitError }
                    return CommitPublishCreatedCommit(
                        commitSHA: "commit-sha",
                        comparisonBase: "origin/main",
                        editorTitle: "Subject"
                    )
                },
                currentHeadSHA: { [unowned self] in
                    calls.append("head")
                    return headSHA
                },
                remoteBranchContainsCommit: { [unowned self] _, _ in
                    calls.append("remoteContainsCommit")
                    return remoteContainsCommit
                },
                push: { [unowned self] _, _ in
                    calls.append("push")
                    if let pushError { throw pushError }
                },
                currentReviewRequestExists: { [unowned self] _ in
                    calls.append("lookupPR")
                    if let lookupError { throw lookupError }
                    return reviewRequestExists
                },
                createReviewRequest: { [unowned self] _, _, _ in
                    calls.append("createPR")
                    if let createRequestError { throw createRequestError }
                    return URL(string: "https://github.com/owner/repository/pull/1")!
                },
                syncGG: { [unowned self] in
                    calls.append("sync")
                    if let syncError { throw syncError }
                },
                refreshAfterCompletion: { [unowned self] in
                    if refreshChecksCheckpoint {
                        checkpointWasClearedBeforeRefresh = checkpoint == nil
                    }
                }
            ),
            onCheckpointChange: { [unowned self] checkpoint in
                self.checkpoint = checkpoint
                if let checkpoint {
                    self.checkpointPhases.append(checkpoint.nextPhase)
                }
            }
        )
    }

    func checkpoint(
        target: CommitPublishReviewTarget? = nil,
        nextPhase: CommitPublishPhase
    ) -> CommitPublishCheckpoint {
        CommitPublishCheckpoint(
            commitSHA: "commit-sha",
            baseRef: "origin/main",
            commitTitle: "Subject",
            subject: "Subject",
            body: "Body",
            destination: .review(target ?? self.target),
            nextPhase: nextPhase
        )
    }
}
