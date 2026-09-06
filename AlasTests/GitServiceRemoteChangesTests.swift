import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
@MainActor
struct GitServiceRemoteChangesTests {
    private func makeRepo() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "test user"], cwd: tmp)
        return tmp
    }

    @Test func changedFilesAgainstRef_includesCommittedAndUncommittedAndUntracked() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "base.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        try "one\ntwo\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "base.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "committed change"], cwd: repo)

        try "dirty\n".write(to: repo.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "dirty.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add dirty"], cwd: repo)
        try "dirty\nedited\n".write(to: repo.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)

        try "new\n".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let files = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: "start")
        #expect(files.map(\.path).sorted() == ["base.txt", "dirty.txt", "untracked.txt"])
        let base = try #require(files.first { $0.path == "base.txt" })
        #expect(base.status == "M")
        #expect(base.add == 1)
        let untracked = try #require(files.first { $0.path == "untracked.txt" })
        #expect(untracked.status == "A")
        #expect(untracked.add == 1)
    }

    @Test func changedFilesAgainstRef_fallsBackToStatusWhenRefIsNil() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        try "hello\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let files = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: nil)
        #expect(files.map(\.path) == ["a.txt"])
    }

    @Test func diffAgainstRef_returnsHunksForACommittedChange() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)
        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "second line"], cwd: repo)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "a.txt")
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }
        #expect(added.map(\.text) == ["two"])
    }

    @Test func diffAgainstRef_showsUntrackedFileAsAllAdd() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)
        try "fresh\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "new.txt")
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }
        #expect(added.map(\.text) == ["fresh"])
    }
}
