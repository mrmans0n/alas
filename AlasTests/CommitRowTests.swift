import Testing
import AppKit
@testable import Alas

struct CommitRowTests {
    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func copiesFullCommitSHA() {
        let commit = CommitInfo(
            sha: "deadbeef1234567890abcdef1234567890abcdef",
            shortSha: "deadbee",
            author: "Nacho Lopez",
            authorInitials: "NL",
            date: Date(),
            subject: "Wire tab_drag",
            conventionalTag: nil,
            filesChanged: 1,
            insertions: 2,
            deletions: 0
        )

        let pasteboard = NSPasteboard(name: .init("io.nlopez.alas.test-commit-copy"))
        pasteboard.clearContents()

        Clipboard.copy(commit.sha, to: pasteboard)

        let copied = pasteboard.string(forType: .string)
        #expect(copied == "deadbeef1234567890abcdef1234567890abcdef")
    }

    @Test func copiesCommitDiffTitle() {
        let pasteboard = NSPasteboard(name: .init("io.nlopez.alas.test-commit-diff-title-copy"))
        pasteboard.clearContents()

        Clipboard.copy("Sources/Center/Commit/CommitDiffView.swift", to: pasteboard)

        let copied = pasteboard.string(forType: .string)
        #expect(copied == "Sources/Center/Commit/CommitDiffView.swift")
    }

    @Test func commitInfoIdUsesSHA() {
        let commit = CommitInfo(
            sha: "aabbccdd11223344556677889900aabbccdd1122",
            shortSha: "aabbccd",
            author: "Nacho Lopez",
            authorInitials: "NL",
            date: Date(),
            subject: "Fix bug",
            conventionalTag: "fix",
            filesChanged: 3,
            insertions: 5,
            deletions: 2
        )

        #expect(commit.id == "aabbccdd11223344556677889900aabbccdd1122")
    }

    @Test func contextMenuShowsReviewCommitImmediatelyAfterEditCommit() {
        #expect(CommitRow.leadingContextMenuActions(canEdit: true, canReview: true) == [.edit, .review])
        #expect(CommitRow.leadingContextMenuActions(canEdit: false, canReview: true) == [.review])
        #expect(CommitRow.leadingContextMenuActions(canEdit: true, canReview: false) == [.edit])
    }

    @Test func contextMenuPlacesGGIDAfterCommitMessage() {
        #expect(CommitRow.copyContextMenuActions(ggID: "c-abc123") == [
            .copySHA,
            .copyMessage,
            .copyGGID("c-abc123"),
        ])
        #expect(CommitRow.copyContextMenuActions(ggID: nil) == [
            .copySHA,
            .copyMessage,
        ])
    }

    @Test func commitGGIDIsEligibleOnlyWhileGGModeIsActive() {
        let commit = CommitInfo(
            sha: "deadbeef1234567890abcdef1234567890abcdef",
            shortSha: "deadbee",
            author: "Nacho Lopez",
            authorInitials: "NL",
            date: Date(),
            subject: "Wire stack identity copy",
            body: "Details.\n\nGG-ID: c-abc123",
            conventionalTag: nil,
            filesChanged: 1,
            insertions: 2,
            deletions: 0
        )

        #expect(CommitsSectionView.contextMenuGGID(for: commit, ggModeEnabled: true) == "c-abc123")
        #expect(CommitsSectionView.contextMenuGGID(for: commit, ggModeEnabled: false) == nil)
    }

    @Test func ggContextMenuUsesStackedDiffsNameAndSharedIcon() {
        #expect(CommitRow.ggContextMenuTitle == "Stacked Diffs (GG)")
        #expect(CommitRow.ggContextMenuSystemImage == "square.stack.3d.up")
        #expect(CommitRow.ggContextMenuSystemImage == GGStackIcon.systemName)
        #expect(GGCommitAction.checkout != .dropCommit)
    }

    @Test func commitRowCarriesOffTipCurrentPositionIndicatorCopy() {
        let indicator = GGCurrentPositionIndicator(
            text: "Current · 2 of 4",
            accessibilityLabel: "Current GG commit, position 2 of 4"
        )
        let row = CommitRow(
            commit: commit(),
            isLast: false,
            onSelect: {},
            onCopySHA: {},
            currentPositionIndicator: indicator
        )

        #expect(row.currentPositionIndicator?.text == "Current · 2 of 4")
        #expect(row.currentPositionIndicator?.accessibilityLabel == "Current GG commit, position 2 of 4")
    }

    @Test func aboveCurrentGGRowRetainsCheckoutAndGuardedMutations() {
        let aboveCurrent = GGStackEntry(position: 4, sha: "four", title: "four")
        let stack = GGStack(
            name: "stack",
            base: "main",
            totalCommits: 4,
            syncedCommits: 0,
            currentPosition: 2,
            behindBase: nil,
            entries: [
                GGStackEntry(position: 1, sha: "one", title: "one"),
                GGStackEntry(position: 2, sha: "two", title: "two", isCurrent: true),
                GGStackEntry(position: 3, sha: "three", title: "three"),
                aboveCurrent,
            ]
        )
        let menu = GGCommitMenuModel.make(context: GGCommitMenuContext(
            entry: aboveCurrent,
            stack: stack,
            provider: nil,
            capabilities: .init(structuredSplit: true, keepCurrentUnstack: true),
            inFlightAction: nil,
            pausedOperation: nil,
            hasBlockingGitOperation: false,
            selectionIsStale: false
        ))

        for action in [GGCommitAction.checkout, .splitCommit, .dropCommit, .unstackHere, .landThrough] {
            #expect(menu.item(for: action) != nil)
        }
    }

    @Test func ggStackChipClickOpensProviderReviewWhenRemoteIsKnown() {
        let entry = GGStackEntry(
            position: 1,
            sha: "deadbee",
            title: "Wire PR chip",
            prNumber: 840
        )
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )

        #expect(
            CommitsSectionView.ggStackChipClickAction(for: entry, remote: remote)
                == .openProviderRequest(number: 840)
        )
    }

    @Test func ggStackChipClickIsUnavailableWithoutProviderReviewTarget() {
        let entryWithReview = GGStackEntry(
            position: 1,
            sha: "deadbee",
            title: "PR without remote",
            prNumber: 840
        )
        let entryWithoutReview = GGStackEntry(
            position: 1,
            sha: "deadbee",
            title: "Local only"
        )
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )

        #expect(CommitsSectionView.ggStackChipClickAction(for: entryWithoutReview, remote: remote) == nil)
        #expect(CommitsSectionView.ggStackChipClickAction(for: entryWithReview, remote: nil) == nil)
    }

    @MainActor
    @Test func copyFeedbackShowsThenDismisses() async throws {
        let feedback = CopyFeedbackState(displayNanoseconds: 10_000_000)

        feedback.show("Copied SHA")

        #expect(feedback.message == "Copied SHA")
        try await waitUntil { feedback.message == nil }
        #expect(feedback.message == nil)
    }

    @MainActor
    @Test func copyFeedbackRefreshKeepsLatestMessageVisible() async throws {
        let feedback = CopyFeedbackState(displayNanoseconds: 2_000_000_000)

        feedback.show("Copied SHA")
        try await Task.sleep(for: .milliseconds(1_100))
        feedback.show("Copied title")
        try await Task.sleep(for: .milliseconds(1_100))

        #expect(feedback.message == "Copied title")
        try await waitUntil { feedback.message == nil }
        #expect(feedback.message == nil)
    }

    private func commit() -> CommitInfo {
        CommitInfo(
            sha: "deadbeef1234567890abcdef1234567890abcdef",
            shortSha: "deadbee",
            author: "Nacho Lopez",
            authorInitials: "NL",
            date: .now,
            subject: "Show current stack position",
            conventionalTag: nil,
            filesChanged: 1,
            insertions: 2,
            deletions: 0
        )
    }
}
