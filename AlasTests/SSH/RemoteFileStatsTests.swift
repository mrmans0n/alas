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
        let command = RemoteFileStats.wcCommand(paths: ["a.txt", "dir/o'brien.txt"])
        #expect(command == [
            "n=$(wc -l < 'a.txt'); if [ -s 'a.txt' ] && [ \"$(tail -c1 -- 'a.txt' | wc -l)\" -eq 0 ]; then n=$((n + 1)); fi; printf '%s %s\\n' \"$n\" 'a.txt'",
            "n=$(wc -l < 'dir/o'\\''brien.txt'); if [ -s 'dir/o'\\''brien.txt' ] && [ \"$(tail -c1 -- 'dir/o'\\''brien.txt' | wc -l)\" -eq 0 ]; then n=$((n + 1)); fi; printf '%s %s\\n' \"$n\" 'dir/o'\\''brien.txt'",
        ].joined(separator: "; "))
    }

    /// Without `--`, a filename starting with `-` (e.g. `-c`) is parsed by
    /// `tail` as an OPTION rather than a filename, silently misclassifying
    /// its trailing-newline check.
    @Test func wcCommandSeparatesOptionsFromFilenamesStartingWithADash() {
        let command = RemoteFileStats.wcCommand(paths: ["-c"])
        #expect(command == "n=$(wc -l < '-c'); if [ -s '-c' ] && [ \"$(tail -c1 -- '-c' | wc -l)\" -eq 0 ]; then n=$((n + 1)); fi; printf '%s %s\\n' \"$n\" '-c'")
    }

    @Test func parsesWcOutput() {
        #expect(RemoteFileStats.parseWcOutput("      12 a.txt\n       0 b.txt\n      12 total", requested: ["a.txt", "b.txt"]) == ["a.txt": 12, "b.txt": 0])
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
    @Test func helperLineCountsMergeDuplicatePaths() {
        let entries = [
            RemoteHelperFSLineCountEntry(path: "file.txt", lineCount: 10),
            RemoteHelperFSLineCountEntry(path: "file.txt", lineCount: 12),
        ]
        #expect(RemoteFileStats.lineCountDictionary(entries) == ["file.txt": 12])
    }
    @Test func parsesLsEntries() {
        let entries = RemoteFileStats.parseLsEntries("src/\nREADME.md\n")
        #expect(entries.count == 2)
        #expect(entries[0].name == "src" && entries[0].isDirectory)
        #expect(entries[1].name == "README.md" && !entries[1].isDirectory)
    }

    /// The GNU (`--zero`) branch of `lsCommand`'s fallback chain emits
    /// NUL-separated entries — a filename containing an embedded newline
    /// byte must stay intact as ONE entry rather than fragmenting into
    /// bogus extras the way newline-splitting would.
    @Test func parsesNULDelimitedLsEntriesKeepingAnEmbeddedNewlineIntact() {
        let output = "weird\nname.txt\0src/\0README.md\0"
        let entries = RemoteFileStats.parseLsEntries(output)
        #expect(entries.count == 3)
        #expect(entries[0].name == "weird\nname.txt" && !entries[0].isDirectory)
        #expect(entries[1].name == "src" && entries[1].isDirectory)
        #expect(entries[2].name == "README.md" && !entries[2].isDirectory)
    }

    @Test func lsCommandChainsGNUZeroThenBSDFallback() {
        let command = RemoteFileStats.lsCommand(path: "/srv/repo/src")
        #expect(command == "ls -1Ap --zero -- '/srv/repo/src' 2>/dev/null || ls -1Ap -- '/srv/repo/src'")
    }
}
