import Foundation
import Testing
@testable import Alas

@Suite("Attention producer")
struct AttentionProducerTests {
    @Test(arguments: [
        (ActivityState.awaitingInput, AttentionKind.agentAwaiting, "session:s1:awaiting", "Codex is waiting for input"),
        (ActivityState.permissionRequest, AttentionKind.agentPermission, "session:s1:permission", "Codex needs permission")
    ])
    func harnessWaitingStatesMapToAttention(
        state: ActivityState, kind: AttentionKind, sourceKey: String, title: String
    ) throws {
        let observations = AttentionProducer.harness(
            sessionID: "s1", agent: .codex, state: state, body: "Need a choice",
            owner: Fixtures.owner, display: Fixtures.display
        )

        let signal = try #require(observations.compactMap(\.activeSignal).first { $0.kind == kind })
        #expect(signal.title == title)
        #expect(signal.sourceKey == AttentionSourceKey(rawValue: sourceKey))
        #expect(signal.fingerprint.hasPrefix("body-sha256:"))
        #expect(signal.fingerprint.count == "body-sha256:".count + 64)
        #expect(!signal.fingerprint.contains("Need a choice"))
        #expect(signal.jumpTarget == .session(sessionID: "s1"))
        let inactiveKey = kind == .agentAwaiting
            ? AttentionSourceKey(rawValue: "session:s1:permission")
            : AttentionSourceKey(rawValue: "session:s1:awaiting")
        #expect(observations.contains { observation in
            if case .inactive(let key) = observation { return key == inactiveKey }
            return false
        })
    }

    @Test func attentionEventsCapPersistedBodiesWithoutMutatingLiveSignal() throws {
        let body = String(repeating: "a", count: 8_193)
        let signal = try #require(AttentionProducer.harness(
            sessionID: "s1", agent: .codex, state: .awaitingInput, body: body,
            owner: Fixtures.owner, display: Fixtures.display
        ).compactMap(\.activeSignal).first)

        let event = AttentionEvent(signal: signal, occurredAt: Date())

        #expect(signal.body == body)
        #expect(event.body?.hasSuffix("\n\n[Output truncated]") == true)
        #expect(event.body != body)
    }

    @Test func scriptFailureMapsExitCodeAndFailureDestination() throws {
        let failure = Fixtures.failure(runID: "run-1", id: "failure-1", exitCode: 23)
        let signal = try #require(AttentionProducer.script(failure: failure, owner: Fixtures.owner, display: Fixtures.display).compactMap(\.activeSignal).first)

        #expect(signal.kind == .runScriptFailure)
        #expect(signal.title == "Build failed with exit code 23")
        #expect(signal.sourceKey == AttentionSourceKey(rawValue: "script:run-1:failure"))
        #expect(signal.fingerprint == "failure-1")
        #expect(signal.jumpTarget == .runScriptFailure(failureID: "failure-1"))
    }

    @Test func scriptFailureOutputMarksTruncationBeforeUtf8Repair() throws {
        let output = String(repeating: "a", count: 8_191) + "é"
        let failure = Fixtures.failure(runID: "run-1", id: "failure-1", exitCode: 23, capturedOutput: .available(text: output, truncated: false))

        let signal = try #require(AttentionProducer.script(failure: failure, owner: Fixtures.owner, display: Fixtures.display).compactMap(\.activeSignal).first)

        #expect(signal.body?.hasSuffix("\n\n[Output truncated]") == true)
        #expect(signal.body?.contains("é") == false)
    }

    @Test(arguments: [
        (MergeOperation.merge(sourceBranch: "main"), "Merge is in progress"),
        (MergeOperation.rebase(plan: RebasePlan(ontoBranch: "main", sourceBranch: "feature", commits: [])), "Rebase is in progress"),
        (MergeOperation.cherryPick(sha: "abc123", summary: "Pick"), "Cherry-pick is in progress")
    ])
    func gitOperationsMapToTheOperationDestination(operation: MergeOperation, title: String) throws {
        let signal = try #require(AttentionProducer.git(operation: operation, changes: [], owner: Fixtures.owner, display: Fixtures.display).compactMap(\.activeSignal).first)

        #expect(signal.kind == .gitOperation)
        #expect(signal.title == title)
        #expect(signal.sourceKey == AttentionSourceKey(rawValue: "git:\(Fixtures.owner.storageKey):operation"))
        #expect(signal.jumpTarget == .gitOperation)
    }

    @Test func rebaseOperationFingerprintIgnoresProgressIndex() throws {
        let first = try #require(AttentionProducer.git(
            operation: .rebase(plan: RebasePlan(
                ontoBranch: "main",
                sourceBranch: "feature",
                commits: [
                    .init(sha: "one", summary: "One", state: .current),
                    .init(sha: "two", summary: "Two", state: .pending)
                ]
            )),
            changes: [],
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first)
        let second = try #require(AttentionProducer.git(
            operation: .rebase(plan: RebasePlan(
                ontoBranch: "main",
                sourceBranch: "feature",
                commits: [
                    .init(sha: "one", summary: "One", state: .done),
                    .init(sha: "two", summary: "Two", state: .current)
                ]
            )),
            changes: [],
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first)

        #expect(first.fingerprint == second.fingerprint)
    }

    @Test func sequencedCherryPickAndRevertFingerprintsIgnoreCurrentCommit() throws {
        let firstPick = try #require(AttentionProducer.git(
            operation: .cherryPick(sha: "one", summary: "One"),
            changes: [],
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first)
        let secondPick = try #require(AttentionProducer.git(
            operation: .cherryPick(sha: "two", summary: "Two"),
            changes: [],
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first)
        let firstRevert = try #require(AttentionProducer.git(
            operation: .revert(sha: "one", summary: "One"),
            changes: [],
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first)
        let secondRevert = try #require(AttentionProducer.git(
            operation: .revert(sha: "two", summary: "Two"),
            changes: [],
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first)

        #expect(firstPick.fingerprint == secondPick.fingerprint)
        #expect(firstRevert.fingerprint == secondRevert.fingerprint)
    }

    @Test func unresolvedConflictFingerprintChangesWithConflictSet() throws {
        let first = try #require(AttentionProducer.git(operation: nil, changes: Fixtures.conflicts(["a.swift"]), owner: Fixtures.owner, display: Fixtures.display).compactMap(\.activeSignal).first)
        let second = try #require(AttentionProducer.git(operation: nil, changes: Fixtures.conflicts(["b.swift", "a.swift"]), owner: Fixtures.owner, display: Fixtures.display).compactMap(\.activeSignal).first)

        #expect(first.kind == .conflicts)
        #expect(first.title == "1 unresolved conflict")
        #expect(first.sourceKey == AttentionSourceKey(rawValue: "git:\(Fixtures.owner.storageKey):conflicts"))
        #expect(first.jumpTarget == .conflicts(path: "a.swift"))
        #expect(second.fingerprint == "7:a.swift7:b.swift")
        #expect(first.fingerprint != second.fingerprint)
    }

    @Test func unresolvedConflictFingerprintDistinguishesDelimiterInPath() throws {
        let singlePath = try #require(AttentionProducer.git(operation: nil, changes: Fixtures.conflicts(["a|b"]), owner: Fixtures.owner, display: Fixtures.display).compactMap(\.activeSignal).first)
        let twoPaths = try #require(AttentionProducer.git(operation: nil, changes: Fixtures.conflicts(["a", "b"]), owner: Fixtures.owner, display: Fixtures.display).compactMap(\.activeSignal).first)

        #expect(singlePath.fingerprint != twoPaths.fingerprint)
    }

    @Test func reviewMappingsExcludePendingChecksAndUnpushedCommits() {
        let observations = AttentionProducer.review(snapshot: Fixtures.review(check: .pending, needsPush: true), owner: Fixtures.owner, display: Fixtures.display)
        #expect(observations.compactMap(\.activeSignal).isEmpty)
    }

    @Test(arguments: [
        (Fixtures.review(check: .fail), AttentionKind.failedChecks, "CI failed"),
        (Fixtures.review(decision: .changesRequested), AttentionKind.actionableFeedback, "Review feedback needs action"),
        (Fixtures.review(needsPush: true, upstreamAhead: 1), AttentionKind.reviewSyncBlocked, "Remote branch diverged"),
        (Fixtures.review(needsPush: false, upstreamAhead: 1), AttentionKind.reviewSyncBlocked, "Remote branch is ahead")
    ])
    func reviewMappingsIncludeOnlyActionableStates(snapshot: ReviewLoopSnapshot, kind: AttentionKind, title: String) throws {
        let signal = try #require(AttentionProducer.review(snapshot: snapshot, owner: Fixtures.owner, display: Fixtures.display).compactMap(\.activeSignal).first { $0.kind == kind })
        #expect(signal.title == title)
        #expect(signal.jumpTarget == .reviewRequest(number: 42))
        if kind != .reviewSyncBlocked {
            #expect(signal.fingerprint.contains("head-1"))
        }
    }

    @Test func reviewSyncBlockedFingerprintIgnoresHeadAndBlockedStateChurn() throws {
        let diverged = try #require(AttentionProducer.review(
            snapshot: Fixtures.review(headSHA: "head-1", needsPush: true, upstreamAhead: 1),
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first { $0.kind == .reviewSyncBlocked })
        let divergedAfterCommit = try #require(AttentionProducer.review(
            snapshot: Fixtures.review(headSHA: "head-2", needsPush: true, upstreamAhead: 1),
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first { $0.kind == .reviewSyncBlocked })
        let staleAfterFetch = try #require(AttentionProducer.review(
            snapshot: Fixtures.review(headSHA: "head-3", needsPush: false, upstreamAhead: 1),
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first { $0.kind == .reviewSyncBlocked })

        #expect(diverged.fingerprint == "sync-blocked")
        #expect(divergedAfterCommit.fingerprint == diverged.fingerprint)
        #expect(staleAfterFetch.fingerprint == diverged.fingerprint)
    }

    @Test func failedCheckFingerprintIgnoresNonFailingCheckChurn() throws {
        let pending = try #require(AttentionProducer.review(
            snapshot: Fixtures.review(checks: [.init(id: "build", name: "Build", workflow: nil, bucket: .fail, detailURL: nil, completedAt: nil),
                                               .init(id: "lint", name: "Lint", workflow: nil, bucket: .pending, detailURL: nil, completedAt: nil)]),
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first { $0.kind == .failedChecks })
        let passing = try #require(AttentionProducer.review(
            snapshot: Fixtures.review(checks: [.init(id: "build", name: "Build", workflow: nil, bucket: .fail, detailURL: nil, completedAt: nil),
                                               .init(id: "lint", name: "Lint", workflow: nil, bucket: .pass, detailURL: nil, completedAt: Date())]),
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first { $0.kind == .failedChecks })

        #expect(pending.fingerprint == passing.fingerprint)
    }

    @Test func actionableFeedbackFingerprintIncludesDecisionWhenThreadSetIsStable() throws {
        let approved = try #require(AttentionProducer.review(
            snapshot: Fixtures.review(decision: .approved, threads: [Fixtures.thread(id: "thread-a")]),
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first { $0.kind == .actionableFeedback })
        let changesRequested = try #require(AttentionProducer.review(
            snapshot: Fixtures.review(decision: .changesRequested, threads: [Fixtures.thread(id: "thread-a")]),
            owner: Fixtures.owner,
            display: Fixtures.display
        ).compactMap(\.activeSignal).first { $0.kind == .actionableFeedback })

        #expect(approved.fingerprint == "head-1|decision|approved|threads|thread-a")
        #expect(changesRequested.fingerprint == "head-1|decision|changesRequested|threads|thread-a")
    }

    @Test func incompleteThreadSnapshotDoesNotEmitFeedbackSignal() {
        let observations = AttentionProducer.review(
            snapshot: Fixtures.review(decision: .changesRequested, threads: [], areThreadsComplete: false),
            owner: Fixtures.owner,
            display: Fixtures.display
        )

        #expect(!observations.compactMap(\.activeSignal).contains { $0.kind == .actionableFeedback })
    }

    @Test func agentReviewReplyUsesReplyIDAndCommentDestination() throws {
        let comment = Fixtures.comment(replyID: "reply-1", author: .agent(name: "Codex"))
        let signal = try #require(AttentionProducer.reviewReply(comment: comment, owner: Fixtures.owner, display: Fixtures.display).compactMap(\.activeSignal).first)

        #expect(signal.kind == .reviewReply)
        #expect(signal.title == "Codex replied to review feedback")
        #expect(signal.sourceKey == AttentionSourceKey(rawValue: "review-comment:\(comment.sessionID.rawValue):comment-1"))
        #expect(signal.fingerprint == "reply-1")
        #expect(signal.jumpTarget == .reviewComment(sessionID: comment.sessionID.rawValue, commentID: "comment-1"))
    }

    @Test func observedAgentReviewReplyEmitsWhenCommentWasResolvedByTheSameCommand() throws {
        let comment = Fixtures.comment(replyID: "reply-1", author: .agent(name: "Codex"), state: .resolved)
        let reply = try #require(comment.allReplies.first)

        let direct = AttentionProducer.reviewReply(comment: comment, owner: Fixtures.owner, display: Fixtures.display)
        let observed = AttentionProducer.reviewReply(comment: comment, observedReply: reply, owner: Fixtures.owner, display: Fixtures.display)

        #expect(direct.compactMap(\.activeSignal).isEmpty)
        #expect(observed.compactMap(\.activeSignal).first?.fingerprint == "reply-1")
    }

    @Test func disconnectedHostMapsToRemoteWorktree() throws {
        let signal = try #require(AttentionProducer.host(host: "buildbox", isDisconnected: true, owner: Fixtures.owner, display: Fixtures.display).compactMap(\.activeSignal).first)
        #expect(signal.kind == .hostDisconnected)
        #expect(signal.title == "buildbox is unreachable")
        #expect(signal.sourceKey == AttentionSourceKey(rawValue: "host:\(Fixtures.owner.storageKey):buildbox:disconnected"))
        #expect(signal.jumpTarget == .remoteWorktree)
    }

    @Test func finishedAgentIsHistoryOnly() {
        let event = AttentionProducer.finished(sessionID: "s1", agent: .codex, owner: Fixtures.owner, display: Fixtures.display)
        #expect(event.kind == .agentFinished)
        #expect(event.title == "Codex finished")
        #expect(event.requiresAction == false)
        #expect(event.jumpTarget == .none)
    }

    private enum Fixtures {
        static let owner = AttentionWorktreeIdentity(projectID: "project", location: .local, lineageID: "lineage", legacyPath: nil)
        static let display = AttentionWorktreeDisplaySnapshot(projectName: "Project", branch: "feature", path: "/repo", host: nil)

        static func failure(
            runID: String,
            id: String,
            exitCode: Int32,
            capturedOutput: RunScriptCapturedOutput = .unavailable
        ) -> RunScriptFailure {
            RunScriptFailure(id: id, runID: runID, scriptKey: "build", scriptName: "Build", worktreeID: "wt", branch: "feature", exitCode: exitCode, completedAt: .distantPast, capturedOutput: capturedOutput)
        }

        static func conflicts(_ paths: [String]) -> [ChangedFile] {
            paths.map { ChangedFile(path: $0, status: "U", stage: .unstaged, add: 0, del: 0, renameFrom: nil, conflict: .bothModified) }
        }

        static func review(
            check: ReviewCheckBucket? = nil,
            decision: ReviewDecision = .approved,
            headSHA: String = "head-1",
            needsPush: Bool = false,
            upstreamAhead: Int = 0,
            threads: [ReviewThread] = [],
            areThreadsComplete: Bool = true
        ) -> ReviewLoopSnapshot {
            review(
                checks: check.map { [ReviewCheck(id: "ci", name: "CI", workflow: nil, bucket: $0, detailURL: nil, completedAt: nil)] } ?? [],
                decision: decision,
                headSHA: headSHA,
                needsPush: needsPush,
                upstreamAhead: upstreamAhead,
                threads: threads,
                areThreadsComplete: areThreadsComplete
            )
        }

        static func review(
            checks: [ReviewCheck],
            decision: ReviewDecision = .approved,
            headSHA: String = "head-1",
            needsPush: Bool = false,
            upstreamAhead: Int = 0,
            threads: [ReviewThread] = [],
            areThreadsComplete: Bool = true
        ) -> ReviewLoopSnapshot {
            let remote = CodeHostRemote(kind: .github, host: "github.com", owner: "owner", repository: "repo", remoteName: "origin", webURL: URL(string: "https://github.com/owner/repo")!)
            let request = ReviewRequest(remote: remote, number: 42, title: "Review", url: remote.webURL, state: .open, isDraft: false, headRefName: "feature", baseRefName: "main", headSHA: headSHA, reviewDecision: decision, mergeState: .clean, checks: checks, threads: threads, areThreadsComplete: areThreadsComplete)
            return ReviewLoopSnapshot(local: ReviewLoopLocalState(branchName: "feature", headSHA: headSHA, baseBranch: "main", hasWorkingTreeChanges: false, hasStagedChanges: false, aheadCommitCount: 0, hasUpstream: true, upstreamAheadCommitCount: upstreamAhead, needsPush: needsPush), remote: remote, reviewRequest: request, providerAvailable: true, providerAuthenticated: true, providerCapabilities: .githubCLI, errorMessage: nil)
        }

        static func thread(id: String) -> ReviewThread {
            ReviewThread(
                id: id,
                path: "a.swift",
                line: 1,
                startLine: nil,
                originalLine: nil,
                diffHunk: nil,
                isResolved: false,
                isOutdated: false,
                isFileLevel: false,
                comments: [],
                viewerCanResolve: true,
                viewerCanReply: true,
                url: nil
            )
        }

        static func comment(replyID: String, author: ReviewDraftCommentAuthor, state: ReviewDraftCommentState = .active) -> ReviewDraftComment {
            ReviewDraftComment(id: "comment-1", sessionID: .localChanges(worktreeID: "wt", worktreePath: URL(fileURLWithPath: "/repo"), scope: .all), fileID: DiffReviewFileID(namespace: "review", path: "a.swift"), path: "a.swift", originalPath: nil, side: .new, startLine: 1, endLine: nil, selectedText: nil, bodyMarkdown: "Fix", state: state, createdAt: .distantPast, updatedAt: .distantPast, replies: [ReviewCommentReply(id: replyID, author: author, bodyMarkdown: "Done", createdAt: .distantPast)])
        }
    }
}
