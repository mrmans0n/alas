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

    @Test func changedFilesAgainstRef_handlesRename() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "content\n".write(to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "old.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add file"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        _ = try await Process.git(["mv", "old.txt", "new.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "rename"], cwd: repo)

        let files = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: "start")
        #expect(files.map(\.path) == ["new.txt"])
        let renamed = try #require(files.first { $0.path == "new.txt" })
        #expect(renamed.status == "R")
        #expect(renamed.renameFrom == "old.txt")
    }

    @Test func diffAgainstRef_fallsBackToWorkingTreeWhenRefIsNil() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)

        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: nil, file: "a.txt")
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }
        #expect(added.map(\.text) == ["two"])
    }

    @Test func diffAgainstRef_handlesDeletedFile() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "content\nline two\n".write(to: repo.appendingPathComponent("deleted.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "deleted.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add file"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        _ = try await Process.git(["rm", "deleted.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "delete"], cwd: repo)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "deleted.txt")
        let deleted = diff.hunks.flatMap(\.lines).filter { $0.kind == .delete }
        #expect(!deleted.isEmpty)
        #expect(deleted.map(\.text).contains("content"))
        #expect(deleted.map(\.text).contains("line two"))
    }

    @Test func isPathIgnored_reportsTrueForAGitignoredPath() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "secret.env\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "TOKEN=abc\n".write(to: repo.appendingPathComponent("secret.env"), atomically: true, encoding: .utf8)

        let ignored = try await GitService().isPathIgnored(worktreePath: repo, path: "secret.env")
        #expect(ignored)
    }

    @Test func isPathIgnored_reportsFalseForATrackedPath() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)

        let ignored = try await GitService().isPathIgnored(worktreePath: repo, path: "a.txt")
        #expect(!ignored)
    }

    @Test func looksBinaryAtRef_sniffsTheBlobWhenTheWorkingTreeFileIsGone() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data([0x42, 0x00, 0x43]).write(to: repo.appendingPathComponent("image.bin"))
        _ = try await Process.git(["add", "image.bin"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add binary"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        _ = try await Process.git(["rm", "image.bin"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "remove binary"], cwd: repo)

        let result = try await GitService().looksBinaryAtRef(worktreePath: repo, ref: "start", file: "image.bin")
        #expect(result == true)
    }

    @Test func looksBinaryAtRef_returnsFalseForATextBlob() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "plain text\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "notes.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add notes"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        _ = try await Process.git(["rm", "notes.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "remove notes"], cwd: repo)

        let result = try await GitService().looksBinaryAtRef(worktreePath: repo, ref: "start", file: "notes.txt")
        #expect(result == false)
    }

    @Test func looksBinaryAtRef_returnsNilWhenTheFileDoesNotExistAtTheRef() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        let result = try await GitService().looksBinaryAtRef(worktreePath: repo, ref: "start", file: "missing.bin")
        #expect(result == nil)
    }

    @Test func isPathIgnored_reportsFalseForAForceAddedTrackedFileMatchingAGitignorePattern() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "forced.log\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "keep me\n".write(to: repo.appendingPathComponent("forced.log"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "-f", "forced.log"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "force add ignored file"], cwd: repo)

        let ignored = try await GitService().isPathIgnored(worktreePath: repo, path: "forced.log")
        #expect(!ignored)
    }
}
