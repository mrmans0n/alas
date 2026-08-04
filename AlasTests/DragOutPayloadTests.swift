import Foundation
import Testing
@testable import Alas

struct DragOutPayloadTests {
    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-dragpayload-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func workingTreeFileJoinsTheWorktreePath() {
        let root = URL(fileURLWithPath: "/tmp/wt")
        let payload = DragOutPayload.workingTreeFile(worktreePath: root, relativePath: "a/b.txt")
        #expect(payload == .onDisk(URL(fileURLWithPath: "/tmp/wt/a/b.txt")))
    }

    @Test func trackedStashFileUsesTheStashRef() {
        let root = URL(fileURLWithPath: "/tmp/wt")
        let stash = GitStash(ref: "stash@{0}", subject: "wip", relativeTime: "1m", sha: "abc")
        let file = GitStashFile(path: "a.txt", status: "M", add: 1, del: 0)
        let payload = DragOutPayload.stashFile(worktreePath: root, stash: stash, file: file)
        #expect(payload == .revision(worktreePath: root, ref: "stash@{0}", path: "a.txt"))
    }

    @Test func untrackedStashFileUsesTheThirdParent() {
        let root = URL(fileURLWithPath: "/tmp/wt")
        let stash = GitStash(ref: "stash@{0}", subject: "wip", relativeTime: "1m", sha: "abc")
        let file = GitStashFile(path: "new.txt", status: "A", add: 3, del: 0, isUntracked: true)
        let payload = DragOutPayload.stashFile(worktreePath: root, stash: stash, file: file)
        #expect(payload == .revision(worktreePath: root, ref: "stash@{0}^3", path: "new.txt"))
    }

    @Test func commitFileUsesTheCommitSHA() {
        let root = URL(fileURLWithPath: "/tmp/wt")
        let file = CommitChangedFile(path: "src/x.swift", originalPath: nil, status: "M", add: 2, del: 1)
        let payload = DragOutPayload.commitFile(worktreePath: root, sha: "a1b2c3d", file: file)
        #expect(payload == .revision(worktreePath: root, ref: "a1b2c3d", path: "src/x.swift"))
    }

    @Test func resolveReturnsAnExistingFile() async throws {
        let dir = try makeTempDir("exists")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        #expect(await DragOutPayload.onDisk(file).resolve() == file)
    }

    @Test func resolveReturnsAnExistingDirectory() async throws {
        let dir = try makeTempDir("dir")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        #expect(await DragOutPayload.onDisk(sub).resolve() == sub)
    }

    @Test func resolveReturnsNilForAMissingFile() async throws {
        let dir = try makeTempDir("missing")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await DragOutPayload.onDisk(dir.appendingPathComponent("gone.txt")).resolve() == nil)
    }

    @Test func resolveReturnsNilInsideARemoteWorktree() async throws {
        let dir = try makeTempDir("remote")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        RemoteHostRegistry.shared.register(root: dir.path, host: "example")
        defer { RemoteHostRegistry.shared.unregister(root: dir.path) }

        #expect(await DragOutPayload.onDisk(file).resolve() == nil)
        let revision = DragOutPayload.revision(worktreePath: dir, ref: "HEAD", path: "a.txt")
        #expect(await revision.resolve() == nil)
    }
}
