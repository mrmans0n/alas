import Testing
import Foundation
@testable import Alas

struct RemoteWorktreeFileAccessTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-file-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func resolvesPlainRelativePathInsideTheWorktree() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "hi\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let resolved = RemoteWorktreeFileAccess.resolve(path: "a.txt", in: root)
        #expect(resolved?.lastPathComponent == "a.txt")
    }

    @Test func rejectsTraversalAbsoluteAndEmptyPaths() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(RemoteWorktreeFileAccess.resolve(path: "../secrets.txt", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: "src/../../secrets.txt", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: "/etc/passwd", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: "", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: "   ", in: root) == nil)
    }

    @Test func rejectsDotGitAtAnyDepth() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(RemoteWorktreeFileAccess.resolve(path: ".git", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: ".git/config", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: "src/.git/config", in: root) == nil)
    }

    @Test func rejectsSymlinkEscapingTheWorktree() throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try "secret\n".write(to: outside.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside)

        #expect(RemoteWorktreeFileAccess.resolve(path: "escape/s.txt", in: root) == nil)
    }

    @Test func truncatesHunksAtTheLineCap() {
        let line = ParsedDiff.Hunk.Line(kind: .add, text: "x", oldNumber: nil, newNumber: 1)
        let big = ParsedDiff.Hunk(
            header: "@@ -0,0 +1,1 @@", oldStart: 0, newStart: 1,
            lines: Array(repeating: line, count: RemoteWorktreeFileAccess.maxDiffLines + 10))
        let small = ParsedDiff.Hunk(
            header: "@@ -0,0 +1,1 @@", oldStart: 0, newStart: 1, lines: [line])

        let truncated = RemoteWorktreeFileAccess.truncateHunks([big])
        #expect(truncated.truncated)
        #expect(truncated.hunks.reduce(0) { $0 + $1.lines.count } == RemoteWorktreeFileAccess.maxDiffLines)

        let kept = RemoteWorktreeFileAccess.truncateHunks([small])
        #expect(!kept.truncated)
        #expect(kept.hunks.count == 1)
    }

    @Test func truncatesChangedFilesAtTheFileCap() {
        let files = (0..<(RemoteWorktreeFileAccess.maxChangedFiles + 5)).map { index in
            ChangedFile(path: "f\(index).txt", status: "M", stage: .unstaged,
                        add: 1, del: 0, renameFrom: nil)
        }
        let result = RemoteWorktreeFileAccess.truncateFiles(files)
        #expect(result.truncated)
        #expect(result.files.count == RemoteWorktreeFileAccess.maxChangedFiles)

        let short = RemoteWorktreeFileAccess.truncateFiles(Array(files.prefix(3)))
        #expect(!short.truncated)
        #expect(short.files.count == 3)
    }

    @Test func rejectsSymlinkAliasToGit() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Create a real .git directory inside the root
        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)

        // Create a config file inside .git
        try "secret\n".write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        // Create a symlink alias that points to .git
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias"),
            withDestinationURL: gitDir)

        // Accessing via the symlink alias should be rejected
        #expect(RemoteWorktreeFileAccess.resolve(path: "alias", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: "alias/config", in: root) == nil)
    }

    @Test func rejectsCaseVariationOfGitOnResolvedPath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Create actual .git directory
        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "secret\n".write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        // Test various case variations - all should be rejected
        // The resolved path check must compare case-insensitively
        #expect(RemoteWorktreeFileAccess.resolve(path: ".GIT/config", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: ".Git/config", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: ".gIT/config", in: root) == nil)
    }
}
