import Foundation
import Testing
@testable import Alas

struct RemoteFileStatsTests {
    @Test func batchesSplitsIntoMaxBatchedPathsSizedChunksInOrder() {
        #expect(RemoteFileStats.batches([]).isEmpty)
        let single = ["a", "b", "c"]
        #expect(RemoteFileStats.batches(single) == [single])

        // 450 paths -> 200/200/50, not silently truncated to the first 200.
        let paths = (0 ..< 450).map { "f\($0).txt" }
        let batches = RemoteFileStats.batches(paths)
        #expect(batches.map(\.count) == [200, 200, 50])
        #expect(batches.flatMap { $0 } == paths)
    }

    @Test func wcCommandQuotesPathsAndAvoidsEmptyInput() {
        #expect(RemoteFileStats.wcCommand(paths: []) == nil)
        let cap = RemoteWorktreeFileAccess.maxFileBytes
        let command = RemoteFileStats.wcCommand(paths: ["a.txt", "dir/o'brien.txt"])
        #expect(command == [
            "size=$(wc -c < 'a.txt'); if [ \"$size\" -gt \(cap) ]; then n=$(head -c \(cap) -- 'a.txt' | wc -l); else n=$(wc -l < 'a.txt'); if [ -s 'a.txt' ] && [ \"$(tail -c1 -- 'a.txt' | wc -l)\" -eq 0 ]; then n=$((n + 1)); fi; fi; printf '%s %s\\0' \"$n\" 'a.txt'",
            "size=$(wc -c < 'dir/o'\\''brien.txt'); if [ \"$size\" -gt \(cap) ]; then n=$(head -c \(cap) -- 'dir/o'\\''brien.txt' | wc -l); else n=$(wc -l < 'dir/o'\\''brien.txt'); if [ -s 'dir/o'\\''brien.txt' ] && [ \"$(tail -c1 -- 'dir/o'\\''brien.txt' | wc -l)\" -eq 0 ]; then n=$((n + 1)); fi; fi; printf '%s %s\\0' \"$n\" 'dir/o'\\''brien.txt'",
        ].joined(separator: "; "))
    }

    /// Without `--`, a filename starting with `-` (e.g. `-c`) is parsed by
    /// `tail`/`head` as an OPTION rather than a filename, silently
    /// misclassifying its trailing-newline check or size cap.
    @Test func wcCommandSeparatesOptionsFromFilenamesStartingWithADash() {
        let cap = RemoteWorktreeFileAccess.maxFileBytes
        let command = RemoteFileStats.wcCommand(paths: ["-c"])
        #expect(command == "size=$(wc -c < '-c'); if [ \"$size\" -gt \(cap) ]; then n=$(head -c \(cap) -- '-c' | wc -l); else n=$(wc -l < '-c'); if [ -s '-c' ] && [ \"$(tail -c1 -- '-c' | wc -l)\" -eq 0 ]; then n=$((n + 1)); fi; fi; printf '%s %s\\0' \"$n\" '-c'")
    }

    /// End-to-end regression for the size cap: a file larger than
    /// `RemoteWorktreeFileAccess.maxFileBytes` must be counted via the
    /// capped `head -c` prefix (an approximate lower bound), not read to
    /// EOF via `wc -l < file` — proven by using a deliberately tiny cap
    /// and a file just past it.
    @Test func wcCommandCapsTheReadForAnOversizedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // One line, no newline, comfortably past a real (512 KiB) cap: a
        // full read would report 1 (the no-trailing-newline adjustment); a
        // capped read of a newline-free prefix must report 0 instead.
        let contents = String(repeating: "x", count: RemoteWorktreeFileAccess.maxFileBytes + 1024)
        try contents.write(to: directory.appendingPathComponent("huge.txt"), atomically: true, encoding: .utf8)

        let command = try #require(RemoteFileStats.wcCommand(paths: ["huge.txt"]))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let counts = RemoteFileStats.parseWcOutput(output, requested: ["huge.txt"])
        #expect(counts["huge.txt"] == 0)
    }

    @Test func parsesWcOutput() {
        #expect(RemoteFileStats.parseWcOutput("      12 a.txt\u{0}       0 b.txt\u{0}", requested: ["a.txt", "b.txt"]) == ["a.txt": 12, "b.txt": 0])
    }

    /// A newline in the path used to fragment a `\n`-delimited record into
    /// two, losing the path→count association (and so silently reporting
    /// `0`). NUL-delimiting fixes this since NUL can't appear in a POSIX
    /// path.
    @Test func parsesWcOutputPreservesANewlineContainingPath() {
        let path = "weird\nname.txt"
        #expect(RemoteFileStats.parseWcOutput("3 \(path)\u{0}", requested: [path]) == [path: 3])
    }

    /// End-to-end regression for the trailing-newline undercount: runs the
    /// generated script through `/bin/sh` against real files, mirroring
    /// what the SSH exec fallback actually executes remotely.
    @Test func wcCommandCorrectlyCountsFilesWithoutATrailingNewline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cases: [(name: String, contents: String, expected: Int)] = [
            ("empty.txt", "", 0),
            ("one-line-no-newline.txt", "hello", 1),
            ("one-line-with-newline.txt", "hello\n", 1),
            ("two-lines-no-trailing-newline.txt", "a\nb", 2),
            ("two-lines-with-trailing-newline.txt", "a\nb\n", 2),
        ]
        for testCase in cases {
            try testCase.contents.write(
                to: directory.appendingPathComponent(testCase.name),
                atomically: true,
                encoding: .utf8
            )
        }

        let paths = cases.map(\.name)
        let command = try #require(RemoteFileStats.wcCommand(paths: paths))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let counts = RemoteFileStats.parseWcOutput(output, requested: paths)
        for testCase in cases {
            #expect(counts[testCase.name] == testCase.expected, "\(testCase.name)")
        }
    }

    /// End-to-end regression for the newline-fragmentation bug: runs the
    /// generated script through `/bin/sh` against a real file whose name
    /// contains an embedded newline byte, mirroring what the SSH exec
    /// fallback actually executes remotely.
    @Test func wcCommandCorrectlyCountsAFileWithANewlineInItsName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let name = "weird\nname.txt"
        try "a\nb\n".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)

        let command = try #require(RemoteFileStats.wcCommand(paths: [name]))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let counts = RemoteFileStats.parseWcOutput(output, requested: [name])
        #expect(counts[name] == 2)
    }

    @Test func helperLineCountsMergeDuplicatePaths() {
        let entries = [
            RemoteHelperFSLineCountEntry(path: "file.txt", lineCount: 10),
            RemoteHelperFSLineCountEntry(path: "file.txt", lineCount: 12),
        ]
        #expect(RemoteFileStats.lineCountDictionary(entries) == ["file.txt": 12])
    }
    @Test func parsesLsEntries() {
        let output = "/root/src\u{0}\(RemoteFileStats.lsSplitMarker)\u{0}/root/README.md\u{0}"
        let entries = RemoteFileStats.parseLsEntries(output)
        #expect(entries.count == 2)
        #expect(entries[0].name == "src" && entries[0].isDirectory)
        #expect(entries[1].name == "README.md" && !entries[1].isDirectory)
    }

    /// `find -print0` is NUL-safe on BOTH GNU findutils and BSD `find` (`ls
    /// --zero`, which this used to be, has no BSD equivalent at all) — a
    /// filename containing an embedded newline byte must stay intact as ONE
    /// entry rather than fragmenting into bogus extras.
    @Test func parsesLsEntriesKeepingAnEmbeddedNewlineIntact() {
        let output = "/root/src\u{0}\(RemoteFileStats.lsSplitMarker)\u{0}/root/weird\nname.txt\u{0}/root/README.md\u{0}"
        let entries = RemoteFileStats.parseLsEntries(output)
        #expect(entries.count == 3)
        #expect(entries[0].name == "src" && entries[0].isDirectory)
        #expect(entries[1].name == "weird\nname.txt" && !entries[1].isDirectory)
        #expect(entries[2].name == "README.md" && !entries[2].isDirectory)
    }

    @Test func lsCommandUsesFindForPortableNULSafety() {
        let command = RemoteFileStats.lsCommand(path: "/srv/repo/src")
        #expect(command == [
            "find '/srv/repo/src' -mindepth 1 -maxdepth 1 -type d -print0",
            "printf '\\0\(RemoteFileStats.lsSplitMarker)\\0'",
            "find '/srv/repo/src' -mindepth 1 -maxdepth 1 ! -type d -print0",
        ].joined(separator: "; "))
    }

    /// End-to-end regression: runs the generated script through `/bin/sh`
    /// against a real directory containing a subdirectory, an ordinary
    /// file, and a file whose name contains an embedded newline byte —
    /// mirroring what the SSH exec fallback actually executes remotely.
    @Test func lsCommandCorrectlyListsADirectoryContainingANewlineNamedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        try "".write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "".write(to: directory.appendingPathComponent("weird\nname.txt"), atomically: true, encoding: .utf8)

        let command = RemoteFileStats.lsCommand(path: directory.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let entries = RemoteFileStats.parseLsEntries(output)
        let names = Set(entries.map(\.name))
        #expect(names == ["subdir", "README.md", "weird\nname.txt"])
        #expect(entries.first { $0.name == "subdir" }?.isDirectory == true)
        #expect(entries.first { $0.name == "README.md" }?.isDirectory == false)
        #expect(entries.first { $0.name == "weird\nname.txt" }?.isDirectory == false)
    }
}
