import Foundation
import Testing
@testable import Alas

@MainActor
struct CommitPublishWorkflowTests {
    @Test func ownerReleasesCompletedRunBeforeRefreshWithoutClearingNewerFailure() async throws {
        let refreshGate = AsyncGate()
        var failSync = false
        let operations = CommitPublishOperations(
            createCommit: { _, _, _ in .init(commitSHA: "committed", comparisonBase: "main", editorTitle: "Title") },
            currentHeadSHA: { "committed" }, remoteBranchContainsCommit: { _, _ in false }, push: { _, _ in },
            currentReviewRequestExists: { _ in true },
            createReviewRequest: { target, _, _ in target.webURL },
            syncGG: {
                if failSync { throw NSError(domain: "Publish", code: 1, userInfo: [NSLocalizedDescriptionKey: "Second failed"]) }
            }, refreshAfterCompletion: { await refreshGate.waitForFirstCall() }
        )
        let session = CommitPublishSession(checkpoint: nil, onCheckpointChange: { _ in }, onCompletion: { _ in })
        let first = try #require(session.run(subject: "First", body: "", amend: false, operations: operations,
            prepareDestination: { .gg() }))
        await refreshGate.waitUntilEntered()
        #expect(!session.isRunning)
        failSync = true
        let second = session.run(subject: "Second", body: "", amend: false, operations: operations,
            prepareDestination: { .gg() })
        #expect(second != nil)
        await second?.value
        await refreshGate.release()
        await first.value
        #expect(session.lastError?.localizedDescription == "Second failed")
        #expect(session.checkpoint?.subject == "Second")
        #expect(!session.isRunning)
    }

    @Test func tabsManagerKeepsSuspendedPublishOwnedAcrossDraftRemount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = TabsManager(tabsDirectory: directory)
        let draft = manager.openOrFocusDraftCommit(worktreeId: "remount-publish")
        let gate = AsyncGate()
        let target = WorkflowHarness().target
        var commits = 0
        var pushes = 0
        let operations = CommitPublishOperations(
            createCommit: { _, _, _ in
                commits += 1
                return .init(commitSHA: "committed", comparisonBase: "main", editorTitle: "Title")
            }, currentHeadSHA: { "committed" }, remoteBranchContainsCommit: { _, _ in false },
            push: { _, _ in pushes += 1
            await gate.waitForFirstCall() },
            currentReviewRequestExists: { _ in true },
            createReviewRequest: { _, _, _ in Issue.record("Unexpected creation")
            return target.webURL },
            syncGG: {}, refreshAfterCompletion: {}
        )
        let task = try #require(manager.runCommitPublish(worktreeId: "remount-publish", tabId: draft.id,
            subject: "Subject", body: "Body", amend: false, operations: operations,
            prepareDestination: { .review(target) }))
        await gate.waitUntilEntered()
        let originalSession = try #require(manager.commitPublishSession(tabId: draft.id))
        #expect(originalSession.isRunning)
        #expect(originalSession.activity == .pushing)

        manager.close(worktreeId: "remount-publish", tabId: draft.id)
        let reopened = manager.openOrFocusDraftCommit(worktreeId: "remount-publish")
        let remountedSession = try #require(manager.commitPublishSession(tabId: reopened.id))
        #expect(remountedSession === originalSession)
        #expect(remountedSession.checkpoint?.nextPhase == .push)
        #expect(manager.runCommitPublish(worktreeId: "remount-publish", tabId: reopened.id,
            subject: "Another subject", body: "", amend: false, operations: operations,
            prepareDestination: { .review(target) }) == nil)
        #expect(commits == 1)
        #expect(pushes == 1)

        await gate.release()
        await task.value
        #expect(!remountedSession.isRunning)
        #expect(remountedSession.checkpoint == nil)
        #expect(manager.commitEditorTab(worktreeId: "remount-publish", currentSha: "committed") != nil)
    }

    @Test func tabsManagerStopsBeforeRemoteMutationWhenCheckpointCannotPersist() async throws {
        let manager = TabsManager(store: FailingTabsStore())
        let draft = manager.openOrFocusDraftCommit(worktreeId: "checkpoint-persist-failure")
        var calls: [String] = []
        let operations = CommitPublishOperations(
            createCommit: { _, _, _ in
                calls.append("commit")
                return .init(commitSHA: "committed", comparisonBase: "main", editorTitle: "Title")
            },
            currentHeadSHA: {
                calls.append("head")
                return "committed"
            },
            remoteBranchContainsCommit: { _, _ in
                calls.append("remoteContainsCommit")
                return false
            },
            push: { _, _ in calls.append("push") },
            currentReviewRequestExists: { _ in true },
            createReviewRequest: { target, _, _ in target.webURL },
            syncGG: {},
            refreshAfterCompletion: {}
        )

        let task = try #require(manager.runCommitPublish(worktreeId: "checkpoint-persist-failure", tabId: draft.id,
            subject: "Subject", body: "Body", amend: false, operations: operations,
            prepareDestination: { .review(WorkflowHarness().target) }))
        await task.value

        let session = try #require(manager.commitPublishSession(tabId: draft.id))
        #expect(calls == ["commit"])
        #expect(session.checkpoint?.nextPhase == .push)
        #expect(session.lastError?.localizedDescription == "write rejected")
    }

    @Test func tabsManagerCanAbandonPausedPublishCheckpoint() async throws {
        let manager = TabsManager()
        let draft = manager.openOrFocusDraftCommit(worktreeId: "abandon-publish")
        let checkpoint = WorkflowHarness().checkpoint(nextPhase: .push)
        manager.updateDraftCommit(worktreeId: "abandon-publish", tabId: draft.id) {
            $0.publishCheckpoint = checkpoint
        }
        let operations = CommitPublishOperations(
            createCommit: { _, _, _ in .init(commitSHA: "unused", comparisonBase: "main", editorTitle: "Unused") },
            currentHeadSHA: { throw WorkflowHarness.Failure.head },
            remoteBranchContainsCommit: { _, _ in false },
            push: { _, _ in },
            currentReviewRequestExists: { _ in true },
            createReviewRequest: { target, _, _ in target.webURL },
            syncGG: {},
            refreshAfterCompletion: {}
        )
        let task = try #require(manager.runCommitPublish(worktreeId: "abandon-publish", tabId: draft.id,
            subject: "Subject", body: "Body", amend: false, operations: operations,
            prepareDestination: { .review(WorkflowHarness().target) }))
        await task.value

        #expect(manager.abandonCommitPublishCheckpoint(worktreeId: "abandon-publish", tabId: draft.id))

        #expect(manager.commitPublishSession(tabId: draft.id) == nil)
        guard case .draftCommit(let state) = manager.tabs(forWorktree: "abandon-publish").first else {
            Issue.record("Expected draft commit tab")
            return
        }
        #expect(state.publishCheckpoint == nil)
    }

    @Test func tabsManagerOpensPostSyncGGHeadAfterCommitPublish() async throws {
        let manager = TabsManager()
        let draft = manager.openOrFocusDraftCommit(worktreeId: "gg-post-sync-head")
        var headSHA = "commit-sha"
        let target = WorkflowHarness().ggTarget
        let operations = CommitPublishOperations(
            createCommit: { _, _, _ in .init(commitSHA: "commit-sha", comparisonBase: "main", editorTitle: "commit- feat") },
            currentHeadSHA: { headSHA },
            remoteBranchContainsCommit: { _, _ in false },
            push: { _, _ in },
            currentReviewRequestExists: { _ in true },
            createReviewRequest: { target, _, _ in target.webURL },
            syncGG: { Issue.record("Unexpected untargeted sync") },
            syncGGForTarget: { _ in headSHA = "rebased-sha" },
            refreshAfterCompletion: {}
        )

        let task = try #require(manager.runCommitPublish(worktreeId: "gg-post-sync-head", tabId: draft.id,
            subject: "feat", body: "", amend: false, operations: operations,
            prepareDestination: { .gg(target) }))
        await task.value

        #expect(manager.commitEditorTab(worktreeId: "gg-post-sync-head", currentSha: "rebased-sha") != nil)
        #expect(manager.commitEditorTab(worktreeId: "gg-post-sync-head", currentSha: "commit-sha") == nil)
    }

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

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .gg())

        #expect(harness.calls == ["commit", "head", "sync", "head"])
        #expect(harness.checkpointPhases == [.sync])
        #expect(harness.checkpoint == nil)
    }

    @Test func ggCheckpointUpdatesExpectedHeadBeforeSync() async {
        let harness = WorkflowHarness()
        let workflow = harness.makeWorkflow()

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .gg(harness.ggTarget))

        #expect(harness.calls == ["validateGGTarget", "commit", "head", "validateGGTarget", "sync", "head"])
        #expect(harness.validatedGGTargets == [
            harness.ggTarget,
            .init(branch: "feature", stackName: "feature", base: "main", expectedHeadSHA: "commit-sha"),
        ])
        #expect(harness.syncedGGTargets == [
            .init(branch: "feature", stackName: "feature", base: "main", expectedHeadSHA: "commit-sha"),
        ])
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

    @Test func changedReviewTargetStopsBeforeCreatingLocalCommit() async {
        var calls: [String] = []
        let target = WorkflowHarness().target
        let operations = CommitPublishOperations(
            validateReviewTarget: { _ in
                calls.append("validateTarget")
                throw CommitPublishWorkflowError.headMismatch(expected: "captured", actual: "changed")
            },
            createCommit: { _, _, _ in
                calls.append("commit")
                return .init(commitSHA: "committed", comparisonBase: "main", editorTitle: "Title")
            },
            currentHeadSHA: { "committed" }, remoteBranchContainsCommit: { _, _ in false },
            push: { _, _ in calls.append("push") }, currentReviewRequestExists: { _ in true },
            createReviewRequest: { target, _, _ in target.webURL }, syncGG: {}, refreshAfterCompletion: {}
        )
        let workflow = CommitPublishWorkflow(operations: operations) { _ in }

        await workflow.start(subject: "Subject", body: "", amend: false, destination: .review(target))

        #expect(calls == ["validateTarget"])
        #expect(workflow.lastError as? CommitPublishWorkflowError == .headMismatch(expected: "captured", actual: "changed"))
    }

    @Test func changedGGTargetStopsBeforeCreatingLocalCommit() async {
        var calls: [String] = []
        let target = WorkflowHarness().ggTarget
        let operations = CommitPublishOperations(
            validateGGTarget: { _ in
                calls.append("validateTarget")
                throw GGMutationError.staleConfirmation
            },
            createCommit: { _, _, _ in
                calls.append("commit")
                return .init(commitSHA: "committed", comparisonBase: "main", editorTitle: "Title")
            },
            currentHeadSHA: { "committed" }, remoteBranchContainsCommit: { _, _ in false }, push: { _, _ in },
            currentReviewRequestExists: { _ in true },
            createReviewRequest: { target, _, _ in target.webURL }, syncGG: {}, refreshAfterCompletion: {}
        )
        let workflow = CommitPublishWorkflow(operations: operations) { _ in }

        await workflow.start(subject: "Subject", body: "", amend: false, destination: .gg(target))

        #expect(calls == ["validateTarget"])
        #expect(workflow.lastError as? GGMutationError == .staleConfirmation)
    }

    @Test func changedGGTargetStopsRetryBeforeSync() async {
        let harness = WorkflowHarness()
        let checkpoint = harness.ggCheckpoint
        var persistedCheckpoint: CommitPublishCheckpoint? = checkpoint
        let operations = CommitPublishOperations(
            validateGGTarget: { _ in throw GGMutationError.staleConfirmation },
            createCommit: { _, _, _ in Issue.record("Unexpected commit")
            return .init(commitSHA: "committed", comparisonBase: "main", editorTitle: "Title") },
            currentHeadSHA: { "commit-sha" }, remoteBranchContainsCommit: { _, _ in false }, push: { _, _ in },
            currentReviewRequestExists: { _ in true },
            createReviewRequest: { target, _, _ in target.webURL }, syncGG: {},
            syncGGForTarget: { _ in Issue.record("Unexpected sync") },
            refreshAfterCompletion: {}
        )
        let workflow = CommitPublishWorkflow(operations: operations) { persistedCheckpoint = $0 }

        await workflow.resume(checkpoint)

        #expect(persistedCheckpoint == checkpoint)
        #expect(workflow.lastError as? GGMutationError == .staleConfirmation)
    }

    @Test func ggRetryRejectsUnrelatedRewrittenHeadBeforeSync() async {
        let harness = WorkflowHarness()
        var persistedCheckpoints: [CommitPublishCheckpoint?] = []
        var syncedTargets: [GGStackTargetIdentity] = []
        let checkpoint = harness.ggCheckpoint
        let operations = CommitPublishOperations(
            createCommit: { _, _, _ in .init(commitSHA: "unused", comparisonBase: "main", editorTitle: "Unused") },
            currentHeadSHA: { "rebased-sha" },
            remoteBranchContainsCommit: { _, _ in false },
            push: { _, _ in },
            currentReviewRequestExists: { _ in true },
            createReviewRequest: { target, _, _ in target.webURL },
            syncGG: { Issue.record("Unexpected untargeted sync") },
            syncGGForTarget: { target in syncedTargets.append(target) },
            refreshAfterCompletion: {}
        )
        let workflow = CommitPublishWorkflow(operations: operations) {
            persistedCheckpoints.append($0)
        }

        await workflow.resume(checkpoint)

        #expect(persistedCheckpoints == [checkpoint])
        #expect(syncedTargets.isEmpty)
        #expect(workflow.lastError as? CommitPublishWorkflowError == .headMismatch(expected: "commit-sha", actual: "rebased-sha"))
    }

    @Test func ggValidationFailureDoesNotPersistRewrittenHeadForRetry() async {
        let harness = WorkflowHarness()
        var headSHA = "commit-sha"
        var persistedCheckpoints: [CommitPublishCheckpoint?] = []
        var syncedTargets: [GGStackTargetIdentity] = []
        let checkpoint = harness.ggCheckpoint
        let operations = CommitPublishOperations(
            validateGGTarget: { _ in
                headSHA = "unrelated-sha"
                throw GGMutationError.staleConfirmation
            },
            createCommit: { _, _, _ in .init(commitSHA: "unused", comparisonBase: "main", editorTitle: "Unused") },
            currentHeadSHA: { headSHA },
            remoteBranchContainsCommit: { _, _ in false },
            push: { _, _ in },
            currentReviewRequestExists: { _ in true },
            createReviewRequest: { target, _, _ in target.webURL },
            syncGG: { Issue.record("Unexpected untargeted sync") },
            syncGGForTarget: { target in syncedTargets.append(target) },
            refreshAfterCompletion: {}
        )
        let workflow = CommitPublishWorkflow(operations: operations) {
            persistedCheckpoints.append($0)
        }

        await workflow.resume(checkpoint)

        #expect(persistedCheckpoints == [checkpoint])
        #expect(syncedTargets.isEmpty)
        #expect(workflow.lastError as? GGMutationError == .staleConfirmation)
    }

    @Test func ggSyncFailurePersistsRewrittenHeadForRetry() async throws {
        let harness = WorkflowHarness()
        var headSHA = "commit-sha"
        var persistedCheckpoints: [CommitPublishCheckpoint?] = []
        var syncedTargets: [GGStackTargetIdentity] = []
        let checkpoint = harness.ggCheckpoint
        let operations = CommitPublishOperations(
            createCommit: { _, _, _ in .init(commitSHA: "unused", comparisonBase: "main", editorTitle: "Unused") },
            currentHeadSHA: { headSHA },
            remoteBranchContainsCommit: { _, _ in false },
            push: { _, _ in },
            currentReviewRequestExists: { _ in true },
            createReviewRequest: { target, _, _ in target.webURL },
            syncGG: { Issue.record("Unexpected untargeted sync") },
            syncGGForTarget: { target in
                syncedTargets.append(target)
                headSHA = "rebased-sha"
                throw WorkflowHarness.Failure.sync
            },
            refreshAfterCompletion: {}
        )
        let workflow = CommitPublishWorkflow(operations: operations) {
            persistedCheckpoints.append($0)
        }

        await workflow.resume(checkpoint)

        #expect(persistedCheckpoints.compactMap { $0?.commitSHA } == ["commit-sha", "rebased-sha"])
        #expect(syncedTargets == [
            .init(branch: "feature", stackName: "feature", base: "main", expectedHeadSHA: "commit-sha"),
        ])
        #expect(workflow.lastError as? WorkflowHarness.Failure == .sync)

        let retryCheckpoint = try #require(persistedCheckpoints.compactMap(\.self).last)
        #expect(retryCheckpoint.commitSHA == "rebased-sha")
        headSHA = "rebased-sha"
        syncedTargets = []
        var retryPersistedCheckpoints: [CommitPublishCheckpoint?] = []
        let retryOperations = CommitPublishOperations(
            createCommit: { _, _, _ in .init(commitSHA: "unused", comparisonBase: "main", editorTitle: "Unused") },
            currentHeadSHA: { headSHA },
            remoteBranchContainsCommit: { _, _ in false },
            push: { _, _ in },
            currentReviewRequestExists: { _ in true },
            createReviewRequest: { target, _, _ in target.webURL },
            syncGG: { Issue.record("Unexpected untargeted sync") },
            syncGGForTarget: { target in syncedTargets.append(target) },
            refreshAfterCompletion: {}
        )
        let retryWorkflow = CommitPublishWorkflow(operations: retryOperations) {
            retryPersistedCheckpoints.append($0)
        }

        await retryWorkflow.resume(retryCheckpoint)

        #expect(retryPersistedCheckpoints.first == retryCheckpoint)
        #expect(syncedTargets == [
            .init(branch: "feature", stackName: "feature", base: "main", expectedHeadSHA: "rebased-sha"),
        ])
        #expect(retryPersistedCheckpoints.last! == nil)
        #expect(retryWorkflow.lastError == nil)
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

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .gg())

        #expect(harness.calls == ["commit", "head", "sync", "head"])
        #expect(harness.checkpoint?.nextPhase == .sync)
    }

    @Test func resumeSyncsWithoutCreatingAnotherCommit() async {
        let harness = WorkflowHarness()
        let workflow = harness.makeWorkflow()
        let checkpoint = CommitPublishCheckpoint(
            commitSHA: "commit-sha",
            baseRef: "origin/main",
            commitTitle: "Subject",
            subject: "Subject",
            body: "Body",
            destination: .gg(),
            nextPhase: .sync
        )
        harness.checkpoint = checkpoint

        await workflow.resume(checkpoint)

        #expect(harness.calls == ["head", "sync", "head"])
        #expect(harness.checkpoint == nil)
    }

    @Test func currentHeadFailureRetainsCheckpoint() async {
        let harness = WorkflowHarness()
        harness.currentHeadError = WorkflowHarness.Failure.head
        let workflow = harness.makeWorkflow()
        let checkpoint = harness.checkpoint(nextPhase: .push)
        harness.checkpoint = checkpoint

        await workflow.resume(checkpoint)

        #expect(harness.calls == ["head"])
        #expect(harness.checkpoint?.nextPhase == .push)
        #expect(workflow.lastError != nil)
    }

    @Test func remoteContainmentFailureRetainsPushCheckpoint() async {
        let harness = WorkflowHarness()
        harness.remoteContainsCommitError = WorkflowHarness.Failure.remoteContainment
        let workflow = harness.makeWorkflow()
        let checkpoint = harness.checkpoint(nextPhase: .push)
        harness.checkpoint = checkpoint

        await workflow.resume(checkpoint)

        #expect(harness.calls == ["head", "remoteContainsCommit"])
        #expect(harness.checkpoint?.nextPhase == .push)
        #expect(workflow.lastError != nil)
    }

    @Test func malformedDestinationAndPhaseRetainsCheckpoint() async {
        let harness = WorkflowHarness()
        let workflow = harness.makeWorkflow()
        let checkpoint = CommitPublishCheckpoint(
            commitSHA: "commit-sha",
            baseRef: "origin/main",
            commitTitle: "Subject",
            subject: "Subject",
            body: "Body",
            destination: .gg(),
            nextPhase: .push
        )
        harness.checkpoint = checkpoint

        await workflow.resume(checkpoint)

        #expect(harness.calls == ["head"])
        #expect(harness.checkpoint == checkpoint)
        #expect((workflow.lastError as? CommitPublishWorkflowError) == .invalidDestination(phase: .push))
    }

    @Test func cancellationAfterPushAdvancesCheckpointWithoutCreatingRequest() async {
        let harness = WorkflowHarness()
        let pushGate = AsyncGate()
        harness.pushGate = pushGate
        let workflow = harness.makeWorkflow()
        let checkpoint = harness.checkpoint(nextPhase: .push)
        harness.checkpoint = checkpoint

        let task = Task { @MainActor in
            await workflow.resume(checkpoint)
        }
        await pushGate.waitUntilEntered()
        task.cancel()
        await pushGate.release()
        await task.value

        #expect(harness.calls == ["head", "remoteContainsCommit", "push"])
        #expect(harness.checkpoint?.nextPhase == .createReviewRequest)
        #expect(workflow.activity == .idle)
        #expect(workflow.lastError == nil)
    }

    @Test func overlappingInvocationsDoNotClobberActiveRun() async {
        let harness = WorkflowHarness()
        let commitGate = AsyncGate()
        harness.createCommitGate = commitGate
        let workflow = harness.makeWorkflow()
        let checkpoint = harness.checkpoint(nextPhase: .push)

        let first = Task { @MainActor in
            await workflow.start(subject: "First", body: "Body", amend: false, destination: .review(harness.target))
        }
        await commitGate.waitUntilEntered()

        await workflow.start(subject: "Second", body: "Body", amend: false, destination: .review(harness.target))
        await workflow.resume(checkpoint)

        #expect(harness.calls == ["commit"])
        #expect(workflow.activity == .committing)
        #expect(workflow.lastError == nil)

        await commitGate.release()
        await first.value

        #expect(workflow.activity == .idle)
        #expect(workflow.lastError == nil)
    }

    @Test func successfulRetryClearsErrorWithoutRepeatingPush() async {
        let harness = WorkflowHarness()
        harness.lookupError = WorkflowHarness.Failure.lookup
        let workflow = harness.makeWorkflow()

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .review(harness.target))
        let checkpoint = try! #require(harness.checkpoint)
        #expect(checkpoint.nextPhase == .createReviewRequest)
        #expect(workflow.lastError != nil)

        harness.lookupError = nil
        harness.calls.removeAll()
        await workflow.resume(checkpoint)

        #expect(harness.calls == ["head", "lookupPR", "createPR"])
        #expect(harness.checkpoint == nil)
        #expect(workflow.lastError == nil)
    }

    @Test func refreshDoesNotBlockNextRun() async {
        let harness = WorkflowHarness()
        let refreshGate = AsyncGate()
        harness.refreshGate = refreshGate
        let workflow = harness.makeWorkflow()
        let checkpoint = harness.checkpoint(nextPhase: .createReviewRequest)
        harness.checkpoint = checkpoint

        let completingRun = Task { @MainActor in
            await workflow.resume(checkpoint)
        }
        await refreshGate.waitUntilEntered()
        #expect(workflow.activity == .idle)

        await workflow.start(subject: "Second", body: "Body", amend: false, destination: .gg())

        #expect(harness.calls == ["head", "lookupPR", "createPR", "commit", "head", "sync", "head"])
        #expect(harness.checkpoint == nil)
        #expect(workflow.lastError == nil)

        await refreshGate.release()
        await completingRun.value
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

    @Test func remoteContainmentStillConfiguresUpstreamForUntrackedBranch() async {
        var calls: [String] = []
        let target = WorkflowHarness().targetWithoutUpstream
        let operations = CommitPublishOperations(
            createCommit: { _, _, _ in .init(commitSHA: "unused", comparisonBase: "main", editorTitle: "Unused") },
            currentHeadSHA: {
                calls.append("head")
                return "commit-sha"
            },
            remoteBranchContainsCommit: { _, _ in
                calls.append("remoteContainsCommit")
                return true
            },
            push: { _, _ in calls.append("push") },
            configureUpstreamTracking: { _ in calls.append("configureUpstream") },
            currentReviewRequestExists: { _ in
                calls.append("lookupPR")
                return true
            },
            createReviewRequest: { target, _, _ in
                calls.append("createPR")
                return target.webURL
            },
            syncGG: {},
            refreshAfterCompletion: {}
        )
        let workflow = CommitPublishWorkflow(operations: operations) { _ in }

        await workflow.resume(WorkflowHarness().checkpoint(target: target, nextPhase: .push))

        #expect(calls == ["head", "remoteContainsCommit", "configureUpstream", "lookupPR"])
    }

    @Test func resumeRepersistsCheckpointBeforeRemoteOperations() async {
        var calls: [String] = []
        let checkpoint = WorkflowHarness().checkpoint(nextPhase: .push)
        let operations = CommitPublishOperations(
            createCommit: { _, _, _ in .init(commitSHA: "unused", comparisonBase: "main", editorTitle: "Unused") },
            currentHeadSHA: {
                calls.append("head")
                return "commit-sha"
            },
            remoteBranchContainsCommit: { _, _ in
                calls.append("remoteContainsCommit")
                return false
            },
            push: { _, _ in calls.append("push") },
            currentReviewRequestExists: { _ in
                calls.append("lookupPR")
                return false
            },
            createReviewRequest: { target, _, _ in
                calls.append("createPR")
                return target.webURL
            },
            syncGG: {},
            refreshAfterCompletion: {}
        )
        let workflow = CommitPublishWorkflow(operations: operations) { next in
            calls.append("persist")
            #expect(next == checkpoint)
            throw NSError(domain: "CommitPublishWorkflowTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "write rejected"])
        }

        await workflow.resume(checkpoint)

        #expect(calls == ["persist"])
        #expect(workflow.lastError?.localizedDescription == "write rejected")
    }

    @Test func freshLookupSkipsCreateWhenRequestNowExists() async {
        let harness = WorkflowHarness()
        harness.reviewRequestExists = true
        let workflow = harness.makeWorkflow()

        await workflow.resume(harness.checkpoint(nextPhase: .createReviewRequest))

        #expect(harness.calls == ["head", "lookupPR"])
    }

    @Test func previouslyExistingRequestSkipsLookupAndCreationAfterPush() async {
        let harness = WorkflowHarness()
        let target = harness.existingRequestTarget
        let workflow = harness.makeWorkflow()

        await workflow.start(subject: "Subject", body: "Body", amend: false, destination: .review(target))

        #expect(harness.calls == ["commit", "head", "remoteContainsCommit", "push"])
        #expect(harness.checkpoint == nil)
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

private struct FailingTabsStore: PersistenceStoreProtocol {
    func write<T: Encodable>(_: T, to _: URL) throws {
        throw NSError(domain: "CommitPublishWorkflowTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "write rejected"])
    }

    func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
}

@MainActor
private final class WorkflowHarness {
    enum Failure: Error {
        case commit
        case head
        case remoteContainment
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
    var currentHeadError: Error?
    var remoteContainsCommitError: Error?
    var pushError: Error?
    var lookupError: Error?
    var createRequestError: Error?
    var syncError: Error?
    var validatedGGTargets: [GGStackTargetIdentity] = []
    var syncedGGTargets: [GGStackTargetIdentity] = []
    var refreshChecksCheckpoint = false
    var checkpointWasClearedBeforeRefresh = false
    var createCommitGate: AsyncGate?
    var pushGate: AsyncGate?
    var refreshGate: AsyncGate?

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

    let ggTarget = GGStackTargetIdentity(
        branch: "feature",
        stackName: "feature",
        base: "main",
        expectedHeadSHA: "before-commit"
    )

    var ggCheckpoint: CommitPublishCheckpoint {
        .init(
            commitSHA: "commit-sha",
            baseRef: "origin/main",
            commitTitle: "Subject",
            subject: "Subject",
            body: "Body",
            destination: .gg(.init(
                branch: "feature",
                stackName: "feature",
                base: "main",
                expectedHeadSHA: "commit-sha"
            )),
            nextPhase: .sync
        )
    }

    let existingRequestTarget = CommitPublishReviewTarget(
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
        reviewRequestExisted: true,
        createAsDraft: false
    )

    func makeWorkflow() -> CommitPublishWorkflow {
        CommitPublishWorkflow(
            operations: CommitPublishOperations(
                validateGGTarget: { [unowned self] target in
                    calls.append("validateGGTarget")
                    validatedGGTargets.append(target)
                },
                createCommit: { [unowned self] _, _, _ in
                    calls.append("commit")
                    if let createCommitGate {
                        await createCommitGate.waitForFirstCall()
                    }
                    if let createCommitError { throw createCommitError }
                    return CommitPublishCreatedCommit(
                        commitSHA: "commit-sha",
                        comparisonBase: "origin/main",
                        editorTitle: "Subject"
                    )
                },
                currentHeadSHA: { [unowned self] in
                    calls.append("head")
                    if let currentHeadError { throw currentHeadError }
                    return headSHA
                },
                remoteBranchContainsCommit: { [unowned self] _, _ in
                    calls.append("remoteContainsCommit")
                    if let remoteContainsCommitError { throw remoteContainsCommitError }
                    return remoteContainsCommit
                },
                push: { [unowned self] _, _ in
                    calls.append("push")
                    if let pushGate {
                        await pushGate.waitForFirstCall()
                    }
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
                syncGGForTarget: { [unowned self] target in
                    calls.append("sync")
                    syncedGGTargets.append(target)
                    if let syncError { throw syncError }
                },
                refreshAfterCompletion: { [unowned self] in
                    if let refreshGate {
                        await refreshGate.waitForFirstCall()
                    }
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

private actor AsyncGate {
    private var hasEntered = false
    private var hasSuspended = false
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForFirstCall() async {
        guard !hasSuspended else { return }
        hasSuspended = true
        hasEntered = true
        entryContinuation?.resume()
        entryContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
