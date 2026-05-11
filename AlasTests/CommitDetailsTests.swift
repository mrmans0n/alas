import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct CommitDetailsTests {
    private func makeRepo() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "test user"], cwd: tmp)
        return tmp
    }

    private func currentSha(in repo: URL) async throws -> String {
        let r = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func parsesNormalCommitWithBody() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "hello\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "feat: greet", "-m", "Adds a greeting file."], cwd: repo)
        let sha = try await currentSha(in: repo)

        let details = try await GitService().commitDetails(at: repo, sha: sha)
        #expect(details.info.sha == sha)
        #expect(details.info.subject == "greet")
        #expect(details.info.conventionalTag == "feat")
        #expect(details.body == "Adds a greeting file.")
        #expect(details.authorEmail == "test@example.com")
        #expect(details.parents.isEmpty)        // initial commit
        #expect(details.files.count == 1)
        #expect(details.files[0].path == "a.txt")
        #expect(details.files[0].status == "A")
        #expect(details.files[0].add == 1)
        #expect(details.files[0].del == 0)
    }

    @Test func parsesCommitWithMultipleFilesAndDeletion() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "x\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "y\n".write(to: repo.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        try "xx\nxx\n".write(to: repo.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        try "n\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "-A"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "change"], cwd: repo)
        let sha = try await currentSha(in: repo)

        let details = try await GitService().commitDetails(at: repo, sha: sha)
        #expect(details.parents.count == 1)
        let byPath = Dictionary(uniqueKeysWithValues: details.files.map { ($0.path, $0) })
        #expect(byPath["keep.txt"]?.status == "M")
        #expect(byPath["gone.txt"]?.status == "D")
        #expect(byPath["new.txt"]?.status == "A")
        #expect(byPath["new.txt"]?.add == 1)
        #expect(byPath["new.txt"]?.del == 0)
    }

    @Test func parsesMergeCommitWithTwoParents() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "base\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: repo)

        _ = try await Process.git(["checkout", "-q", "-b", "side"], cwd: repo)
        try "side\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "side change"], cwd: repo)

        _ = try await Process.git(["checkout", "-q", "main"], cwd: repo)
        try "main\n".write(to: repo.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "main change"], cwd: repo)

        _ = try await Process.git(["merge", "--no-ff", "-q", "-m", "merge: side into main", "side"], cwd: repo)
        let sha = try await currentSha(in: repo)

        let details = try await GitService().commitDetails(at: repo, sha: sha)
        #expect(details.parents.count == 2)
        // First-parent diff: merging `side` into `main` brings b.txt from side.
        let paths = details.files.map(\.path).sorted()
        #expect(paths == ["b.txt"])
        let b = details.files.first { $0.path == "b.txt" }
        #expect(b?.status == "A")
        #expect(b?.add == 1)
    }
}
