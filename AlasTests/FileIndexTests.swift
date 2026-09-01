import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct FileIndexTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-fi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        // Identity needed for commits in CI.
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "Test"], cwd: dir)
        return dir
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func enumeratesTrackedFiles() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write("hi", to: repo.appendingPathComponent("a.txt"))
        try write("hi", to: repo.appendingPathComponent("nested/b.txt"))
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)

        let entries = try await FileIndex().entries(forWorktreePath: repo)
        let paths = entries.map(\.relativePath).sorted()
        #expect(paths == ["a.txt", "nested/b.txt"])
    }

    @Test func includesUntrackedRespectsGitignore() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write("ignored\n", to: repo.appendingPathComponent(".gitignore"))
        _ = try await Process.git(["add", ".gitignore"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try write("hi", to: repo.appendingPathComponent("tracked.txt"))
        try write("hi", to: repo.appendingPathComponent("ignored"))
        try write("hi", to: repo.appendingPathComponent("untracked.txt"))

        let entries = try await FileIndex().entries(forWorktreePath: repo)
        let paths = Set(entries.map(\.relativePath))
        #expect(paths.contains(".gitignore"))
        #expect(paths.contains("tracked.txt"))
        #expect(paths.contains("untracked.txt"))
        #expect(!paths.contains("ignored"))
    }

    @Test func extIsLowercaseAndNoDot() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write("hi", to: repo.appendingPathComponent("Foo.RS"))
        try write("hi", to: repo.appendingPathComponent("Bar.toml"))
        try write("hi", to: repo.appendingPathComponent("Makefile"))

        let entries = try await FileIndex().entries(forWorktreePath: repo)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0.ext) })
        #expect(byPath["Foo.RS"] == "rs")
        #expect(byPath["Bar.toml"] == "toml")
        #expect(byPath["Makefile"] == "")
    }

    @Test func enumeratesNonAsciiPaths() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let nonAscii = "résumé.txt"
        try write("hi", to: repo.appendingPathComponent(nonAscii))
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)

        let entries = try await FileIndex().entries(forWorktreePath: repo)
        #expect(entries.contains(where: { $0.relativePath == nonAscii }))
    }

    @Test func invalidatesLocationQualifiedLocalCacheKey() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write("hi", to: repo.appendingPathComponent("first.txt"))
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        let index = FileIndex()
        let worktree = SearchWorktree(
            id: repo.path,
            projectId: "project",
            displayName: "Repo",
            absolutePath: repo,
            executionLocation: .local
        )

        let first = try await index.entries(for: worktree)
        try write("hi", to: repo.appendingPathComponent("second.txt"))
        await index.invalidate(forWorktreePath: repo)
        let second = try await index.entries(for: worktree)

        #expect(first.map(\.relativePath) == ["first.txt"])
        #expect(second.map(\.relativePath).contains("second.txt"))
    }
}
