import Foundation
import Testing
@testable import Alas

@Suite("Review session models")
struct ReviewSessionModelsTests {
    @Test func consolidationMergesVerdictWithReviewedStatus() {
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc",
            title: "Review abc"
        )
        let existing = ReviewSessionRecord(
            id: target.id,
            target: target,
            status: .sent,
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 2)
        )
        let source = ReviewSessionRecord(
            id: ReviewSessionID(rawValue: "source"),
            target: target,
            status: .reviewed,
            verdict: ReviewSessionVerdict(
                verdict: .approve,
                summary: "Looks good",
                reviewedAt: .init(timeIntervalSince1970: 3)
            ),
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 4)
        )

        let merged = ReviewSessionConsolidation.merge(existing: existing, source: source)

        #expect(merged.verdict == source.verdict)
        #expect(merged.status == .reviewed)
    }

    @Test func localChangesTargetDerivesStableIDs() {
        let repositoryPath = URL(fileURLWithPath: "/repo")
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            scope: .unstaged
        )

        #expect(target.kind == .localChanges)
        #expect(target.id.rawValue == "local-changes\u{1f}wt-1\u{1f}/repo\u{1f}unstaged")
        #expect(target.draftSessionID == .localChanges(worktreeID: "wt-1", worktreePath: repositoryPath, scope: .unstaged))
        #expect(target.title == "Review unstaged changes")
        #expect(target.sourceDescription == "Local changes: unstaged")
    }

    @Test func providerTargetIncludesProviderIdentity() {
        let repositoryPath = URL(fileURLWithPath: "/repo/../repo")
        let target = ReviewSessionTarget.reviewRequest(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            provider: .github,
            host: "GitHub.com",
            repositorySlug: "mrmans0n/alas",
            number: 520,
            url: URL(string: "https://github.com/mrmans0n/alas/pull/520")!,
            title: "Use shared surface",
            headSHA: "abc123"
        )

        #expect(target.kind == .reviewRequest)
        #expect(target.repositoryPath.path == "/repo")
        #expect(target.id.rawValue == "review-request\u{1f}wt-1\u{1f}/repo\u{1f}github\u{1f}github.com\u{1f}mrmans0n/alas\u{1f}520")
        #expect(target.draftSessionID == .reviewRequest(worktreeID: "wt-1", provider: .github, host: "github.com", repositorySlug: "mrmans0n/alas", number: 520))
        #expect(target.providerDescription == "GitHub mrmans0n/alas #520")
        #expect(target.revisionDescription == "abc123")
    }

    @Test func commitStyleTargetsDeriveDraftSessions() {
        let repositoryPath = URL(fileURLWithPath: "/repo/../repo")
        let draft = ReviewSessionTarget.draftCommit(worktreeID: "wt-1", repositoryPath: repositoryPath)
        let commit = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            sha: "deadbeef",
            title: "Review deadbeef"
        )
        let range = ReviewSessionTarget.commitRange(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            base: "main",
            head: "feature"
        )
        let branch = ReviewSessionTarget.branch(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            base: "main",
            head: "feature"
        )

        #expect(draft.draftSessionID == .draftCommit(worktreeID: "wt-1", repositoryPath: repositoryPath))
        #expect(commit.draftSessionID == .commit(worktreeID: "wt-1", repositoryPath: repositoryPath, sha: "deadbeef"))
        #expect(range.draftSessionID == .commitRange(worktreeID: "wt-1", repositoryPath: repositoryPath, base: "main", head: "feature"))
        #expect(branch.draftSessionID == .branch(worktreeID: "wt-1", repositoryPath: repositoryPath, base: "main", head: "feature"))
        #expect(draft.id.rawValue == "draft-commit\u{1f}wt-1\u{1f}/repo")
        #expect(commit.sourceDescription == "Commit deadbeef")
        #expect(range.sourceDescription == "Commit range main..feature")
        #expect(branch.sourceDescription == "Branch feature against main")
    }

    @Test func trackedCommitIdentityUsesExpressionNotResolvedSHA() throws {
        let repositoryPath = URL(fileURLWithPath: "/repo/../repo")
        let revision = try #require(TrackedRevision(
            expression: " HEAD~3 ", baselineBranch: "feature", resolvedSHA: "aaa"
        ))
        let first = ReviewSessionTarget.trackedCommit(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            revision: revision,
            title: "Review HEAD~3"
        )
        let moved = revision.resolving(.init(branch: "feature", sha: "bbb"))
        let second = first.updatingTrackedRevision(moved, title: "Review rewritten commit")

        #expect(first.kind == .trackedCommit)
        #expect(first.id == second.id)
        #expect(first.draftSessionID == second.draftSessionID)
        #expect(first.draftSessionID == .trackedCommit(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            expression: "HEAD~3"
        ))
        #expect(second.revisionDescription == "HEAD~3 -> bbb")
        #expect(second.sourceDescription == "Commit HEAD~3 -> bbb")
        #expect(second.freezingTrackedRevision(title: "Fixed")?.payload == .commit(sha: "bbb"))
    }

    @Test func draftReviewRequestTargetUsesRepositoryPathDraftID() {
        let repositoryPath = URL(fileURLWithPath: "/repo")
        let target = ReviewSessionTarget.draftReviewRequest(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            provider: .gitlab,
            repositorySlug: "mrmans0n/alas",
            base: "main",
            head: "feature",
            headSHA: "abc123"
        )

        #expect(target.kind == .draftReviewRequest)
        #expect(target.id.rawValue == "draft-review-request\u{1f}wt-1\u{1f}/repo\u{1f}gitlab\u{1f}mrmans0n/alas\u{1f}main\u{1f}feature\u{1f}abc123")
        #expect(target.draftSessionID == .draftReviewRequest(worktreeID: "wt-1", repositoryPath: repositoryPath, base: "main", head: "feature"))
        #expect(target.providerDescription == "GitLab mrmans0n/alas")
        #expect(target.revisionDescription == "abc123")
    }

    @Test func handoffTransitionsToSentAndAddressed() {
        let record = ReviewSessionRecord(
            id: ReviewSessionID(rawValue: "session-1"),
            target: .commit(
                worktreeID: "wt-1",
                repositoryPath: URL(fileURLWithPath: "/repo"),
                sha: "deadbeef",
                title: "Review deadbeef"
            ),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let handoff = ReviewFeedbackHandoff(
            id: "handoff-1",
            sessionID: record.id,
            commentIDs: ["c1", "c2"],
            target: .existingSession(worktreeID: "wt-1", sessionID: "acp-1", title: "Codex"),
            createdAt: Date(timeIntervalSince1970: 30),
            promptRevision: "rev-1",
            status: .sent
        )

        let withHandoff = record.recording(handoff: handoff)
        #expect(withHandoff.status == .sent)
        #expect(withHandoff.updatedAt == Date(timeIntervalSince1970: 30))
        #expect(withHandoff.handoffs == [handoff])
        #expect(withHandoff.markedAddressed(now: Date(timeIntervalSince1970: 40)).status == .addressed)
    }

    @Test func promptRevisionChangesWhenIncludedCommentsChange() {
        let first = ReviewFeedbackHandoff.revisionKey(commentIDs: ["b", "a"], prompt: "hello")
        let second = ReviewFeedbackHandoff.revisionKey(commentIDs: ["a", "b"], prompt: "hello")
        let third = ReviewFeedbackHandoff.revisionKey(commentIDs: ["a", "b"], prompt: "different")

        #expect(first == second)
        #expect(first != third)
    }

    @Test func recordSelectionHelpersUpdateStateAndTimestamp() {
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let fileID = DiffReviewFileID(namespace: "unstaged", path: "Sources/A.swift")

        let selected = record.selectingFile(fileID, now: Date(timeIntervalSince1970: 20))
        #expect(selected.selectedFileID == fileID)
        #expect(selected.updatedAt == Date(timeIntervalSince1970: 20))

        let focused = selected.focusingComment("comment-1", now: Date(timeIntervalSince1970: 30))
        #expect(focused.focusedCommentID == "comment-1")
        #expect(focused.updatedAt == Date(timeIntervalSince1970: 30))
    }

    @Test func markingReviewedStoresTheVerdictAndEndsTheSession() {
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        let reviewed = record.markedReviewed(
            verdict: .approve,
            summary: "Looks good.",
            now: Date(timeIntervalSince1970: 20)
        )

        #expect(reviewed.status == .reviewed)
        #expect(reviewed.verdict == ReviewSessionVerdict(
            verdict: .approve,
            summary: "Looks good.",
            reviewedAt: Date(timeIntervalSince1970: 20)
        ))
        #expect(reviewed.updatedAt == Date(timeIntervalSince1970: 20))
        #expect(reviewed.markedAddressed(now: Date(timeIntervalSince1970: 30)).status == .reviewed)
    }

    @Test func retargetingTrackedCommitReopensVerdictAndPreservesHandoffs() throws {
        let revision = try #require(TrackedRevision(
            expression: "HEAD~3", baselineBranch: "feature", resolvedSHA: "aaa"
        ))
        let target = ReviewSessionTarget.trackedCommit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            revision: revision,
            title: "Review HEAD~3"
        )
        let handoff = ReviewFeedbackHandoff(
            id: "handoff-1",
            sessionID: target.id,
            commentIDs: ["comment-1"],
            target: .existingSession(worktreeID: "wt-1", sessionID: "acp-1", title: "Codex"),
            createdAt: Date(timeIntervalSince1970: 30),
            promptRevision: "rev-1",
            status: .sent
        )
        let reviewed = ReviewSessionRecord(
            id: target.id,
            target: target,
            status: .reviewed,
            verdict: ReviewSessionVerdict(
                verdict: .approve,
                summary: "Looks good",
                reviewedAt: Date(timeIntervalSince1970: 40)
            ),
            handoffs: [handoff],
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 40)
        )
        let movedTarget = target.updatingTrackedRevision(
            revision.resolving(.init(branch: "feature", sha: "bbb")),
            title: "Review rewritten commit"
        )

        let moved = reviewed.retargetingCommit(
            to: movedTarget,
            resolvedSHAChanged: true,
            now: Date(timeIntervalSince1970: 50)
        )
        let unchanged = reviewed.retargetingCommit(
            to: target,
            resolvedSHAChanged: false,
            now: Date(timeIntervalSince1970: 60)
        )

        #expect(moved.status == .active)
        #expect(moved.verdict == nil)
        #expect(moved.handoffs == reviewed.handoffs)
        #expect(moved.updatedAt == Date(timeIntervalSince1970: 50))
        #expect(unchanged.status == .reviewed)
        #expect(unchanged.verdict == reviewed.verdict)
    }

    @Test func consolidationUsesRetargetedRecordStateAfterRevisionMoves() throws {
        let repositoryPath = URL(fileURLWithPath: "/repo")
        let sourceTarget = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            sha: "aaa",
            title: "Review aaa"
        )
        let movedRevision = try #require(TrackedRevision(
            expression: "HEAD~3",
            baselineBranch: "feature",
            resolvedSHA: "bbb"
        ))
        let destinationTarget = ReviewSessionTarget.trackedCommit(
            worktreeID: "wt-1",
            repositoryPath: repositoryPath,
            revision: movedRevision,
            title: "Review HEAD~3"
        )
        let source = ReviewSessionRecord(
            id: sourceTarget.id,
            target: sourceTarget,
            status: .reviewed,
            verdict: ReviewSessionVerdict(
                verdict: .approve,
                summary: "Old bytes were good",
                reviewedAt: Date(timeIntervalSince1970: 40)
            ),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 40)
        )
        let existing = ReviewSessionRecord(
            id: destinationTarget.id,
            target: destinationTarget,
            status: .sent,
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let result = try #require(TrackedRevisionRetargeter.follow(
            record: source,
            revision: movedRevision,
            title: "Review HEAD~3",
            now: Date(timeIntervalSince1970: 50)
        ))

        let merged = ReviewSessionConsolidation.merge(existing: existing, source: result.record)

        #expect(result.record.verdict == nil)
        #expect(result.record.status == .active)
        #expect(merged.verdict == nil)
        #expect(merged.status == .sent)
    }
}
