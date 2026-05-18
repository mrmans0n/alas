import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
@MainActor
struct RightPaneStateDiscardTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-rpsd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "t"], cwd: dir)
        return dir
    }

    private func write(_ repo: URL, _ name: String, _ contents: String) throws {
        try contents.write(
            to: repo.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeState(at path: URL) -> RightPaneState {
        let wt = Worktree(
            id: Worktree.makeId(path: path),
            projectId: "p",
            name: "test",
            branch: "main",
            path: path,
            status: .clean,
            lastActivity: Date()
        )
        return RightPaneState(worktree: wt, baseBranch: "main")
    }

    private func porcelain(at repo: URL) async throws -> String {
        let r = try await Process.git(["status", "--porcelain"], cwd: repo)
        return r.stdout
    }

    @Test func requestDiscardFileSetsPendingFromChanges() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write(repo, "a.txt", "v1\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try write(repo, "a.txt", "v2\n")

        let rps = makeState(at: repo)
        await rps.refresh()
        rps.requestDiscardFile(path: "a.txt")
        #expect(rps.pendingDiscard?.target == .file(path: "a.txt"))
        #expect(rps.pendingDiscard?.paths == ["a.txt"])
    }

    @Test func requestDiscardFileForUnknownPathIsNoOp() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write(repo, "a.txt", "v1\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)

        let rps = makeState(at: repo)
        await rps.refresh()
        rps.requestDiscardFile(path: "missing.txt")
        #expect(rps.pendingDiscard == nil)
    }

    @Test func cancelDiscardClearsStateAndLeavesRepoUntouched() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write(repo, "a.txt", "v1\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try write(repo, "a.txt", "v2\n")

        let rps = makeState(at: repo)
        await rps.refresh()
        rps.requestDiscardFile(path: "a.txt")
        let before = try await porcelain(at: repo)
        rps.cancelDiscard()
        let after = try await porcelain(at: repo)
        #expect(rps.pendingDiscard == nil)
        #expect(before == after)
    }

    @Test func confirmDiscardFileRunsGitAndClearsPending() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write(repo, "a.txt", "v1\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try write(repo, "a.txt", "v2\n")

        let rps = makeState(at: repo)
        await rps.refresh()
        rps.requestDiscardFile(path: "a.txt")

        var closedPaths: [String] = []
        rps.closeDiffTabs = { closedPaths.append(contentsOf: $0) }
        await rps.confirmDiscard()

        let contents = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(contents == "v1\n")
        #expect(rps.pendingDiscard == nil)
        #expect(closedPaths == ["a.txt"])
    }

    @Test func confirmDiscardFolderHonoursPrefix() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try write(repo, "src/a.txt", "v1\n")
        try write(repo, "outside.txt", "v1\n")
        _ = try await Process.git(["add", "."], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try write(repo, "src/a.txt", "v2\n")
        try write(repo, "outside.txt", "v2\n")

        let rps = makeState(at: repo)
        await rps.refresh()
        rps.requestDiscardFolder(path: "src")
        await rps.confirmDiscard()

        let inside = try String(contentsOf: repo.appendingPathComponent("src/a.txt"), encoding: .utf8)
        let outside = try String(contentsOf: repo.appendingPathComponent("outside.txt"), encoding: .utf8)
        #expect(inside == "v1\n")
        #expect(outside == "v2\n")
    }

    @Test func confirmDiscardAllClearsWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try write(repo, "a.txt", "v1\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try write(repo, "a.txt", "v2\n")
        try write(repo, "u.txt", "new\n")

        let rps = makeState(at: repo)
        await rps.refresh()
        rps.requestDiscardAll()
        await rps.confirmDiscard()

        let contents = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(contents == "v1\n")
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("u.txt").path))
    }
}
