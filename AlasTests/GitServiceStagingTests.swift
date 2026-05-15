import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct GitServiceStagingTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-stg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "t"], cwd: dir)
        return dir
    }

    private func writeFile(_ repo: URL, _ name: String, _ contents: String) throws {
        try contents.write(
            to: repo.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test func stageMovesFileToIndex() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "a.txt", "hello\n")
        let svc = GitService()
        try await svc.stage(worktreePath: repo, files: ["a.txt"])
        let status = try await svc.status(worktreePath: repo)
        #expect(status.contains { $0.path == "a.txt" && $0.stage == .staged })
    }

    @Test func unstageRemovesFromIndex() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "a.txt", "hello\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try writeFile(repo, "a.txt", "hello world\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)

        let svc = GitService()
        try await svc.unstage(worktreePath: repo, files: ["a.txt"])
        let status = try await svc.status(worktreePath: repo)
        #expect(status.contains { $0.path == "a.txt" && $0.stage == .unstaged })
        #expect(!status.contains { $0.path == "a.txt" && $0.stage == .staged })
    }

    @Test func unstageOnUnbornBranchUsesReset() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // Create a fresh repo with no commits and stage a new file.
        let unborn = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-unborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unborn) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: unborn)
        try writeFile(unborn, "a.txt", "x\n")
        _ = try await Process.git(["add", "a.txt"], cwd: unborn)

        let svc = GitService()
        try await svc.unstage(worktreePath: unborn, files: ["a.txt"])
        let status = try await svc.status(worktreePath: unborn)
        // After unstage on unborn HEAD, the file should be untracked (status "A" / unstaged).
        #expect(status.contains { $0.path == "a.txt" && $0.stage == .unstaged })
    }

    @Test func stageAllPicksUpEveryUnstagedPath() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "a.txt", "1")
        try writeFile(repo, "b.txt", "2")
        let svc = GitService()
        try await svc.stageAll(worktreePath: repo, files: ["a.txt", "b.txt"])
        let status = try await svc.status(worktreePath: repo)
        #expect(status.filter { $0.stage == .staged }.count == 2)
    }

    @Test func unstageAllClearsIndex() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "a.txt", "1")
        try writeFile(repo, "b.txt", "2")
        _ = try await Process.git(["add", "a.txt", "b.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try writeFile(repo, "a.txt", "11")
        try writeFile(repo, "b.txt", "22")
        _ = try await Process.git(["add", "a.txt", "b.txt"], cwd: repo)

        let svc = GitService()
        try await svc.unstageAll(worktreePath: repo, files: ["a.txt", "b.txt"])
        let status = try await svc.status(worktreePath: repo)
        #expect(status.filter { $0.stage == .staged }.isEmpty)
    }

    @Test func stageDeletedFileRecordsDeletion() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeFile(repo, "a.txt", "x\n")
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "init"], cwd: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("a.txt"))

        let svc = GitService()
        try await svc.stage(worktreePath: repo, files: ["a.txt"])
        let status = try await svc.status(worktreePath: repo)
        #expect(status.contains { $0.path == "a.txt" && $0.stage == .staged && $0.status == "D" })
    }
}
