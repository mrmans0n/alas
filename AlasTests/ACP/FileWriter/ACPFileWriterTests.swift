import Foundation
import Testing
@testable import Alas

@Suite("ACPFileWriter")
struct ACPFileWriterTests {
    private func makeWorktree() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("writes a new file inside the worktree and reports added lines")
    func writeNew() throws {
        let wt = try makeWorktree()
        defer { try? FileManager.default.removeItem(at: wt) }
        let writer = ACPFileWriter(worktreeRoot: wt)
        let result = try writer.write(path: wt.appendingPathComponent("a.txt").path,
                                      content: "one\ntwo\nthree\n")
        #expect(result.added == 3)
        #expect(result.removed == 0)
        #expect(result.oldText == nil)
        #expect(result.newText == "one\ntwo\nthree\n")
        #expect(FileManager.default.fileExists(atPath: wt.appendingPathComponent("a.txt").path))
    }

    @Test("overwrites and reports correct +N -M")
    func overwrite() throws {
        let wt = try makeWorktree()
        defer { try? FileManager.default.removeItem(at: wt) }
        let p = wt.appendingPathComponent("b.txt")
        try "alpha\nbeta\ngamma\n".write(to: p, atomically: true, encoding: .utf8)
        let writer = ACPFileWriter(worktreeRoot: wt)
        let result = try writer.write(path: p.path, content: "alpha\nGAMMA\ndelta\n")
        #expect(result.added == 2)
        #expect(result.removed == 2)
        #expect(result.oldText == "alpha\nbeta\ngamma\n")
        #expect(result.newText == "alpha\nGAMMA\ndelta\n")
    }

    @Test("rejects writes outside the worktree")
    func rejectOutside() {
        let wt = URL(fileURLWithPath: "/tmp/acp-wt-outside")
        let writer = ACPFileWriter(worktreeRoot: wt)
        #expect(throws: ACPFileWriter.Error.self) {
            _ = try writer.write(path: "/etc/passwd", content: "x")
        }
    }

    @Test("resolveInsideWorktree rejects paths outside the worktree")
    func resolveOutside() throws {
        let wt = try makeWorktree()
        defer { try? FileManager.default.removeItem(at: wt) }
        let writer = ACPFileWriter(worktreeRoot: wt)
        #expect(throws: ACPFileWriter.Error.self) {
            _ = try writer.resolveInsideWorktree(path: "/etc/passwd")
        }
    }

    @Test("resolveInsideWorktree accepts files inside the worktree")
    func resolveInside() throws {
        let wt = try makeWorktree()
        defer { try? FileManager.default.removeItem(at: wt) }
        let writer = ACPFileWriter(worktreeRoot: wt)
        let target = wt.appendingPathComponent("inside.txt").path
        let resolved = try writer.resolveInsideWorktree(path: target)
        #expect(resolved.path == target)
    }

    @Test("resolveInsideWorktree preserves symlinked worktree spelling after boundary validation")
    func resolveInsidePreservesSymlinkedWorktreePath() throws {
        let physical = try makeWorktree()
        let symlink = physical.deletingLastPathComponent().appendingPathComponent("wt-link-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: symlink)
            try? FileManager.default.removeItem(at: physical)
        }
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: physical)
        let requested = symlink.appendingPathComponent("inside.txt").path
        let writer = ACPFileWriter(worktreeRoot: symlink)

        let resolved = try writer.resolveInsideWorktree(path: requested)

        #expect(resolved.path == requested)
        #expect(resolved.path != physical.appendingPathComponent("inside.txt").path)
    }

    @Test("writes through contained symlinks without replacing the link")
    func writeThroughContainedSymlink() throws {
        let wt = try makeWorktree()
        defer { try? FileManager.default.removeItem(at: wt) }
        let target = wt.appendingPathComponent("target.txt")
        let link = wt.appendingPathComponent("link.txt")
        try "old\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")
        let writer = ACPFileWriter(worktreeRoot: wt)

        let result = try writer.write(path: link.path, content: "new\n")

        #expect(result.path == link.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "target.txt")
        #expect(try String(contentsOf: target, encoding: .utf8) == "new\n")
    }
}
