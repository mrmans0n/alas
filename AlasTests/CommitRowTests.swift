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

        func copySHA(_ commit: CommitInfo) {
            let pb = NSPasteboard(name: .init("io.nlopez.alas.test-commit-copy"))
            pb.clearContents()
            pb.setString(commit.sha, forType: .string)
        }

        copySHA(commit)

        let copied = pasteboard.string(forType: .string)
        #expect(copied == "deadbeef1234567890abcdef1234567890abcdef")
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
}
