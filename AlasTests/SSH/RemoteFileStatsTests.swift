import Testing
@testable import Alas

struct RemoteFileStatsTests {
    @Test func wcCommandQuotesPathsAndAvoidsEmptyInput() {
        #expect(RemoteFileStats.wcCommand(paths: []) == nil)
        #expect(RemoteFileStats.wcCommand(paths: ["a.txt", "dir/o'brien.txt"]) == "wc -l -- 'a.txt' 'dir/o'\\''brien.txt'")
    }

    /// Without `--`, a filename starting with `-` (e.g. `-c`) is parsed by
    /// `wc` as an OPTION rather than a filename, silently dropping it from
    /// the output — and so silently reporting 0 for its line count.
    @Test func wcCommandSeparatesOptionsFromFilenamesStartingWithADash() {
        #expect(RemoteFileStats.wcCommand(paths: ["-c"]) == "wc -l -- '-c'")
    }

    @Test func parsesWcOutput() {
        #expect(RemoteFileStats.parseWcOutput("      12 a.txt\n       0 b.txt\n      12 total", requested: ["a.txt", "b.txt"]) == ["a.txt": 12, "b.txt": 0])
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
