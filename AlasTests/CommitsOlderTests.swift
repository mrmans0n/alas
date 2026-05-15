import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct CommitsOlderTests {
    private func makeLinearRepo(commits: Int) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-co-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "test"], cwd: tmp)
        for i in 1...commits {
            try "\(i)\n".write(to: tmp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            _ = try await Process.git(["add", "."], cwd: tmp)
            _ = try await Process.git(["commit", "-q", "-m", "feat: step \(i)"], cwd: tmp)
        }
        return tmp
    }

    @Test func returnsExactlyNCommitsBeforeRef() async throws {
        let repo = try await makeLinearRepo(commits: 25)
        defer { try? FileManager.default.removeItem(at: repo) }
        let svc = GitService()
        let result = try await svc.commitsOlder(worktreePath: repo, beforeSha: "HEAD", count: 20)
        #expect(result.count == 20)
        #expect(result[0].subject == "step 24")
        #expect(result[19].subject == "step 5")
    }

    @Test func returnsFewerWhenAncestorsRunOut() async throws {
        let repo = try await makeLinearRepo(commits: 5)
        defer { try? FileManager.default.removeItem(at: repo) }
        let svc = GitService()
        let result = try await svc.commitsOlder(worktreePath: repo, beforeSha: "HEAD", count: 20)
        #expect(result.count == 4)
        #expect(result.map(\.subject) == ["step 4", "step 3", "step 2", "step 1"])
    }

    @Test func cursorByShaStartsFromParent() async throws {
        let repo = try await makeLinearRepo(commits: 10)
        defer { try? FileManager.default.removeItem(at: repo) }
        let log = try await Process.git(["log", "--grep", "step 5$", "--pretty=%H"], cwd: repo)
        let step5 = log.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let svc = GitService()
        let result = try await svc.commitsOlder(worktreePath: repo, beforeSha: step5, count: 3)
        #expect(result.map(\.subject) == ["step 4", "step 3", "step 2"])
    }

    @Test func usesFirstParentOnMergeAncestry() async throws {
        let repo = try await makeLinearRepo(commits: 3)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["checkout", "-q", "-b", "side"], cwd: repo)
        try "side\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "feat: side work"], cwd: repo)
        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
        _ = try await Process.git(["merge", "-q", "--no-ff", "--no-edit", "side"], cwd: repo)

        let svc = GitService()
        let result = try await svc.commitsOlder(worktreePath: repo, beforeSha: "HEAD", count: 10)
        #expect(!result.map(\.subject).contains("side work"))
        #expect(result.map(\.subject).contains("step 3"))
    }

    @Test func throwsOnInvalidSha() async throws {
        let repo = try await makeLinearRepo(commits: 3)
        defer { try? FileManager.default.removeItem(at: repo) }
        let svc = GitService()
        await #expect(throws: (any Error).self) {
            _ = try await svc.commitsOlder(worktreePath: repo, beforeSha: "deadbeefdeadbeef", count: 5)
        }
    }
}
