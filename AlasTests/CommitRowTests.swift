import Testing
import AppKit
@testable import Alas

struct CommitRowTests {
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

    @MainActor
    @Test func copyFeedbackShowsThenDismisses() async throws {
        let feedback = CopyFeedbackState(displayNanoseconds: 10_000_000)

        feedback.show("Copied SHA")

        #expect(feedback.message == "Copied SHA")
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(feedback.message == nil)
    }

    @MainActor
    @Test func copyFeedbackRefreshKeepsLatestMessageVisible() async throws {
        let feedback = CopyFeedbackState(displayNanoseconds: 50_000_000)

        feedback.show("Copied SHA")
        try await Task.sleep(nanoseconds: 20_000_000)
        feedback.show("Copied title")
        try await Task.sleep(nanoseconds: 35_000_000)

        #expect(feedback.message == "Copied title")
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(feedback.message == nil)
    }
}
