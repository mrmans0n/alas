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
        #expect(result.added == 2)   // GAMMA, delta
        #expect(result.removed == 2) // beta, gamma
    }

    @Test("rejects writes outside the worktree")
    func rejectOutside() {
        let wt = URL(fileURLWithPath: "/tmp/acp-wt-outside")
        let writer = ACPFileWriter(worktreeRoot: wt)
        #expect(throws: ACPFileWriter.Error.self) {
            _ = try writer.write(path: "/etc/passwd", content: "x")
        }
    }
}
