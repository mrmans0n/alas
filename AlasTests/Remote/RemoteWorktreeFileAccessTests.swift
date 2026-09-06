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

    @Test func truncatesHunksAtTheByteBudgetBeforeTheLineCap() {
        // Each line is 2KB; at 2KB/line the byte budget (512KB) is exhausted
        // long before the 2,000-line cap would be, so this hunk must be
        // stopped by the byte budget rather than the line count.
        let text = String(repeating: "a", count: 2048)
        let line = ParsedDiff.Hunk.Line(kind: .add, text: text, oldNumber: nil, newNumber: 1)
        let hunk = ParsedDiff.Hunk(
            header: "@@ -0,0 +1,1 @@", oldStart: 0, newStart: 1,
            lines: Array(repeating: line, count: RemoteWorktreeFileAccess.maxDiffLines))

        let result = RemoteWorktreeFileAccess.truncateHunks([hunk])

        #expect(result.truncated)
        let keptLines = result.hunks.reduce(0) { $0 + $1.lines.count }
        #expect(keptLines < RemoteWorktreeFileAccess.maxDiffLines)
        let totalBytes = result.hunks.reduce(0) { total, hunk in
            total + hunk.lines.reduce(0) { $0 + $1.text.utf8.count }
        }
        #expect(totalBytes <= RemoteWorktreeFileAccess.maxDiffBytes)
    }

    @Test func truncatesASingleEnormousLineRatherThanShippingOrDroppingItWhole() throws {
        let hugeText = String(repeating: "x", count: 2 * 1024 * 1024) // 2 MB single line
        let hugeLine = ParsedDiff.Hunk.Line(kind: .add, text: hugeText, oldNumber: nil, newNumber: 1)
        let normalLine = ParsedDiff.Hunk.Line(kind: .add, text: "y", oldNumber: nil, newNumber: 2)
        let hunk = ParsedDiff.Hunk(
            header: "@@ -0,0 +1,2 @@", oldStart: 0, newStart: 1,
            lines: [hugeLine, normalLine])

        let result = RemoteWorktreeFileAccess.truncateHunks([hunk])

        #expect(result.truncated)
        let totalBytes = result.hunks.reduce(0) { total, hunk in
            total + hunk.lines.reduce(0) { $0 + $1.text.utf8.count }
        }
        #expect(totalBytes <= RemoteWorktreeFileAccess.maxDiffBytes)
        let firstLine = try #require(result.hunks.first?.lines.first)
        #expect(firstLine.text.utf8.count <= RemoteWorktreeFileAccess.maxDiffLineBytes)
        #expect(firstLine.text.hasSuffix("(line truncated)"))
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

    @Test func normalizedRelativePathTrimsWhitespaceToMatchTheTrimmedForm() {
        #expect(RemoteWorktreeFileAccess.normalizedRelativePath(" secret.env") == "secret.env")
        #expect(
            RemoteWorktreeFileAccess.normalizedRelativePath(" secret.env")
                == RemoteWorktreeFileAccess.normalizedRelativePath("secret.env"))
        #expect(RemoteWorktreeFileAccess.normalizedRelativePath("\tsrc/file.txt\n") == "src/file.txt")
    }

    @Test func normalizedRelativePathRejectsTheSameInputsAsResolve() {
        #expect(RemoteWorktreeFileAccess.normalizedRelativePath("") == nil)
        #expect(RemoteWorktreeFileAccess.normalizedRelativePath("   ") == nil)
        #expect(RemoteWorktreeFileAccess.normalizedRelativePath("/etc/passwd") == nil)
        #expect(RemoteWorktreeFileAccess.normalizedRelativePath("../secrets.txt") == nil)
        #expect(RemoteWorktreeFileAccess.normalizedRelativePath(".git/config") == nil)
    }

    @Test func readFileContentsReportsTooLargeFromStatWithoutReadingTheWholeFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("big.txt")
        let oversized = RemoteWorktreeFileAccess.maxFileBytes + 1
        // A sparse file (seek-then-write) gets the real on-disk byte size
        // reported by stat without materializing the buffer in memory —
        // the point of this test is exercising the stat-before-read path,
        // not proving multi-GB behavior.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(oversized - 1))
        handle.write(Data([0x41]))
        try handle.close()

        let outcome = await RemoteWorktreeFileAccess.readFileContents(at: url)

        guard case .tooLarge(let byteSize) = outcome else {
            Issue.record("expected .tooLarge, got \(outcome)")
            return
        }
        #expect(byteSize == oversized)
    }

    @Test func readFileContentsReportsNotFoundForAMissingFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = await RemoteWorktreeFileAccess.readFileContents(at: root.appendingPathComponent("missing.txt"))

        #expect(outcome == .notFound)
    }

    @Test func readFileContentsReturnsTextForASmallUTF8File() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("small.txt")
        try "hello\n".write(to: url, atomically: true, encoding: .utf8)

        let outcome = await RemoteWorktreeFileAccess.readFileContents(at: url)

        #expect(outcome == .text("hello\n"))
    }

    @Test func readFileContentsReportsBinaryForANulContainingFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bin.dat")
        try Data([0x41, 0x00, 0x42]).write(to: url)

        let outcome = await RemoteWorktreeFileAccess.readFileContents(at: url)

        #expect(outcome == .binary(byteSize: 3))
    }

    @Test func looksBinaryOnDiskSniffsWithoutReadingTheWholeFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let textURL = root.appendingPathComponent("text.txt")
        try "clean text\n".write(to: textURL, atomically: true, encoding: .utf8)
        let binaryURL = root.appendingPathComponent("binary.dat")
        try Data([0x00, 0x01, 0x02]).write(to: binaryURL)

        #expect(await RemoteWorktreeFileAccess.looksBinaryOnDisk(at: textURL) == false)
        #expect(await RemoteWorktreeFileAccess.looksBinaryOnDisk(at: binaryURL) == true)
    }
}
