import Testing
@testable import Alas

struct ACPTurnDiffSessionBuilderTests {
    private func diff(_ header: String) -> ParsedDiff {
        ParsedDiff(hunks: [ParsedDiff.Hunk(
            header: header, oldStart: 1, newStart: 1,
            lines: [.init(kind: .add, text: "x", oldNumber: nil, newNumber: 1, noTrailingNewline: false)]
        )])
    }

    @Test func labelsEachEditsHunksWhenAFileWasEditedMoreThanOnce() {
        let combined = ACPTurnDiffSessionBuilder.combine([
            .diff(diff("@@ -0,0 +1 @@"), change: .added),
            .note("Recorded diff unavailable"),
            .diff(diff("@@ -3 +3 @@"), change: .modified),
        ])

        #expect(combined.diff.hunks.map(\.header) == ["Edit 1 of 3 · @@ -0,0 +1 @@", "Edit 3 of 3 · @@ -3 +3 @@"])
        #expect(combined.diff.metadataSummary == "Edit 2 of 3: Recorded diff unavailable")
        #expect(combined.status == .added)
    }

    @Test func keepsASingleEditsHunkHeader() {
        let combined = ACPTurnDiffSessionBuilder.combine([.diff(diff("@@ -3 +3 @@"), change: .deleted)])

        #expect(combined.diff.hunks.map(\.header) == ["@@ -3 +3 @@"])
        #expect(combined.status == .deleted)
    }
}
