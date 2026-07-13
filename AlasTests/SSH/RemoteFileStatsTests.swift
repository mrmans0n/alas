import Testing
@testable import Alas

struct RemoteFileStatsTests {
    @Test func wcCommandQuotesPathsAndAvoidsEmptyInput() {
        #expect(RemoteFileStats.wcCommand(paths: []) == nil)
        #expect(RemoteFileStats.wcCommand(paths: ["a.txt", "dir/o'brien.txt"]) == "wc -l 'a.txt' 'dir/o'\\''brien.txt'")
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
}
