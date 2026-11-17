import Testing
import AlasCore

struct LineDiffTests {
    @Test func lineDiffGroupsChangesIntoHunksWithContext() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        var lines = (1...20).map { "line \($0)" }
        lines[1] = "changed 2"
        lines[17] = "changed 18"
        let diff = LineDiff.parsedDiff(old: old, new: lines.joined(separator: "\n"), context: 3)
        #expect(diff.hunks.count == 2)
        #expect(diff.hunks[0].header == "@@ -1,5 +1,5 @@")
        #expect(diff.hunks[0].lines.filter { $0.kind == .delete }.map(\.text) == ["line 2"])
        #expect(diff.hunks[0].lines.filter { $0.kind == .add }.map(\.text) == ["changed 2"])
        #expect(diff.hunks[1].lines.first { $0.kind == .add }?.newNumber == 18)
    }

    @Test func lineDiffOfANewFileIsOneAddHunk() {
        let diff = LineDiff.parsedDiff(old: nil, new: "a\nb")
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].lines.map(\.kind) == [.add, .add])
    }

    @Test func lineDiffSplitsCRLFLines() {
        let diff = LineDiff.parsedDiff(old: "a\r\nb\r\n", new: "a\r\nc\r\n")
        #expect(diff.hunks.map(\.header) == ["@@ -1,2 +1,2 @@"])
        #expect(diff.hunks[0].lines.map(\.text) == ["a", "b", "c"])
    }
}
