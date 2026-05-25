import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct GitServiceCommitEditingTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@example.com"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "Tester"], cwd: dir)
        return dir
    }

    private func write(_ repo: URL, _ path: String, _ text: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func commit(_ repo: URL, subject: String, files: [String: String]) async throws -> String {
        for (path, text) in files { try write(repo, path, text) }
        _ = try await Process.git(["add", "--"] + Array(files.keys), cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", subject], cwd: repo)
        let head = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
        return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func subjects(_ repo: URL) async throws -> [String] {
        let result = try await Process.git(["log", "--reverse", "--pretty=format:%s"], cwd: repo)
        return result.stdout.split(separator: "\n").map(String.init)
    }

    @Test func rewordAboveFoldCommitPreservesDescendant() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["base.txt": "base\n"])
        let target = try await commit(repo, subject: "old target", files: ["a.txt": "a1\n"])
        let descendant = try await commit(repo, subject: "descendant", files: ["b.txt": "b1\n"])

        let result = try await GitService().editCommit(
            worktreePath: repo,
            baseRef: base,
            targetSha: target,
            action: .message(subject: "new target", body: "body text")
        )

        #expect(result.currentSha != target)
        #expect(result.shaMap[target] == result.currentSha)
        #expect(result.shaMap[descendant] != nil)
        #expect(try await subjects(repo) == ["base", "new target", "descendant"])
        let body = try await Process.git(["log", "-1", "--pretty=format:%b", result.currentSha], cwd: repo)
        #expect(body.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "body text")
    }

    @Test func rewordRejectsBelowFoldCommit() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["base.txt": "base\n"])
        _ = try await commit(repo, subject: "above", files: ["a.txt": "a\n"])

        await #expect(throws: CommitEditError.self) {
            _ = try await GitService().editCommit(
                worktreePath: repo,
                baseRef: base,
                targetSha: base,
                action: .message(subject: "bad", body: "")
            )
        }
    }

    @Test func rewordRejectsDirtyWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let base = try await commit(repo, subject: "base", files: ["base.txt": "base\n"])
        let target = try await commit(repo, subject: "target", files: ["a.txt": "a\n"])
        try write(repo, "dirty.txt", "dirty\n")

        await #expect(throws: CommitEditError.self) {
            _ = try await GitService().editCommit(
                worktreePath: repo,
                baseRef: base,
                targetSha: target,
                action: .message(subject: "new", body: "")
            )
        }
    }
}
