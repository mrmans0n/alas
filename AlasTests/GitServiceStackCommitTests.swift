import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct GitServiceStackCommitTests {
    private struct TwoCommitRepo {
        let repo: URL
        let base: String
        let tip: String
    }

    private func makeTwoCommitRepo() async throws -> TwoCommitRepo {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-stack-commits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "committer@example.com"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "Committer"], cwd: repo)

        try "base\n".write(to: repo.appendingPathComponent("stack.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "stack.txt"], cwd: repo)
        _ = try await Process.git(
            ["commit", "-q", "--author", "Base Author <base@example.com>", "-m", "feat: base layer", "-m", "Base details."],
            cwd: repo
        )
        let base = try await resolvedHead(in: repo)

        try "base\ntip\n".write(to: repo.appendingPathComponent("stack.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "stack.txt"], cwd: repo)
        _ = try await Process.git(
            ["commit", "-q", "--author", "Tip Author <tip@example.com>", "-m", "fix: tip layer", "-m", "Tip details."],
            cwd: repo
        )
        return TwoCommitRepo(repo: repo, base: base, tip: try await resolvedHead(in: repo))
    }

    private func resolvedHead(in repo: URL) async throws -> String {
        let result = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func record(
        sha: String,
        shortSHA: String,
        author: String = "Test Author",
        subject: String = "feat: test record",
        body: String = "Details.",
        numstat: String = "1\t0\tfile.txt"
    ) -> String {
        "\u{1e}\(sha)\u{1f}\(shortSHA)\u{1f}\(author)\u{1f}2024-01-02T03:04:05Z\u{1f}\(subject)\u{1f}\(body)\u{1d}\n\(numstat)"
    }

    @Test func loadsRequestedCommitsByFullResolvedSHA() async throws {
        let fixture = try await makeTwoCommitRepo()
        defer { try? FileManager.default.removeItem(at: fixture.repo) }

        let infos = try await GitService().stackCommitInfos(
            at: fixture.repo,
            shas: [String(fixture.tip.prefix(7)), String(fixture.base.prefix(7))]
        )

        #expect(Set(infos.keys) == [fixture.base, fixture.tip])
        #expect(infos[fixture.base]?.subject == "base layer")
        #expect(infos[fixture.base]?.conventionalTag == "feat")
        #expect(infos[fixture.tip]?.body == "Tip details.")
        #expect(infos[fixture.tip]?.filesChanged == 1)
    }

    @Test func emptySHAListDoesNotInvokeGit() async throws {
        #expect(try await GitService().stackCommitInfos(
            at: URL(fileURLWithPath: "/missing"),
            shas: [String]()
        ) == [:])
    }

    @Test func unavailableSHAFailsTheWholeBatch() async throws {
        let fixture = try await makeTwoCommitRepo()
        defer { try? FileManager.default.removeItem(at: fixture.repo) }

        await #expect(throws: StackCommitInfoError.self) {
            _ = try await GitService().stackCommitInfos(at: fixture.repo, shas: [fixture.tip, "deadbeef"])
        }
    }

    @Test func parserIndexesReversedRecordsByResolvedSHA() throws {
        let base = String(repeating: "a", count: 40)
        let tip = String(repeating: "b", count: 40)
        let infos = try GitService.parseStackCommitInfoRecords(
            record(sha: tip, shortSHA: "bbbbbbb", author: "Tip Author", subject: "fix: tip", numstat: "2\t1\ttip.txt")
                + record(sha: base, shortSHA: "aaaaaaa", author: "Base Author", subject: "feat: base")
        )

        #expect(Set(infos.keys) == [base, tip])
        #expect(infos[base]?.subject == "base")
        #expect(infos[tip]?.subject == "tip")
        #expect(infos[tip]?.insertions == 2)
        #expect(infos[tip]?.deletions == 1)
    }

    @Test func parserRejectsMalformedHeaderFields() {
        let malformed = "\u{1e}abc\u{1f}def\u{1f}Author\u{1f}2024-01-02T03:04:05Z\u{1f}subject\u{1d}\n1\t0\tfile.txt"

        #expect(throws: StackCommitInfoError.malformedRecord) {
            try GitService.parseStackCommitInfoRecords(malformed)
        }
    }

    @Test func parserRejectsNumstatWithExtraTabSeparatedField() {
        let sha = String(repeating: "e", count: 40)

        #expect(throws: StackCommitInfoError.malformedRecord) {
            try GitService.parseStackCommitInfoRecords(
                record(sha: sha, shortSHA: "eeeeeee", numstat: "1\t0\tfile.txt\textra")
            )
        }
    }

    @Test func parserCountsBinaryNumstatAsChangedFileWithoutLines() throws {
        let sha = String(repeating: "c", count: 40)
        let infos = try GitService.parseStackCommitInfoRecords(
            record(sha: sha, shortSHA: "ccccccc", numstat: "-\t-\tblob.bin")
        )

        #expect(infos[sha]?.filesChanged == 1)
        #expect(infos[sha]?.insertions == 0)
        #expect(infos[sha]?.deletions == 0)
    }

    @Test func parserRejectsDuplicateResolvedSHAs() {
        let sha = String(repeating: "d", count: 40)
        let duplicate = record(sha: sha, shortSHA: "ddddddd") + record(sha: sha, shortSHA: "ddddddd")

        #expect(throws: StackCommitInfoError.malformedRecord) {
            try GitService.parseStackCommitInfoRecords(duplicate)
        }
    }
}
