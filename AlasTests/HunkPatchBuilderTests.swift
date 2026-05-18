import Testing
@testable import Alas

struct HunkPatchBuilderTests {
    private func hunk(_ header: String, _ lines: [ParsedDiff.Hunk.Line]) -> ParsedDiff.Hunk {
        ParsedDiff.Hunk(header: header, oldStart: 1, newStart: 1, lines: lines)
    }

    private func ctx(_ s: String) -> ParsedDiff.Hunk.Line {
        .init(kind: .context, text: s, oldNumber: 1, newNumber: 1)
    }
    private func add(_ s: String) -> ParsedDiff.Hunk.Line {
        .init(kind: .add, text: s, oldNumber: nil, newNumber: 1)
    }
    private func del(_ s: String) -> ParsedDiff.Hunk.Line {
        .init(kind: .delete, text: s, oldNumber: 1, newNumber: nil)
    }

    @Test func trackedFilePatchHasStandardHeader() {
        let h = hunk("@@ -10,3 +10,4 @@", [ctx("a"), add("b"), del("c")])
        let patch = HunkPatchBuilder.patch(file: "src/a.swift", hunk: h, tracked: true)
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "diff --git a/src/a.swift b/src/a.swift")
        #expect(lines[1] == "--- a/src/a.swift")
        #expect(lines[2] == "+++ b/src/a.swift")
        #expect(lines[3] == "@@ -10,3 +10,4 @@")
        #expect(lines[4] == " a")
        #expect(lines[5] == "+b")
        #expect(lines[6] == "-c")
        // Trailing newline → final element empty
        #expect(patch.hasSuffix("\n"))
    }

    @Test func untrackedFilePatchHasNewFileHeader() {
        let h = hunk("@@ -0,0 +1,1 @@", [add("hello")])
        let patch = HunkPatchBuilder.patch(file: "new.txt", hunk: h, tracked: false)
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "diff --git a/new.txt b/new.txt")
        #expect(lines[1] == "new file mode 100644")
        #expect(lines[2] == "--- /dev/null")
        #expect(lines[3] == "+++ b/new.txt")
        #expect(lines[4] == "@@ -0,0 +1,1 @@")
        #expect(lines[5] == "+hello")
        #expect(patch.hasSuffix("\n"))
    }

    @Test func nonAsciiPathPassesThroughUnescaped() {
        let h = hunk("@@ -1,1 +1,1 @@", [add("x")])
        let patch = HunkPatchBuilder.patch(file: "café/π.swift", hunk: h, tracked: true)
        #expect(patch.contains("a/café/π.swift"))
        #expect(patch.contains("b/café/π.swift"))
    }

    @Test func untrackedFilePatchUsesProvidedMode() {
        // Stage hunk on a new executable script must emit `new file mode 100755`
        // so `git apply --cached` doesn't drop the +x bit.
        let h = hunk("@@ -0,0 +1,1 @@", [add("#!/bin/sh")])
        let patch = HunkPatchBuilder.patch(
            file: "run.sh", hunk: h, tracked: false, untrackedMode: "100755"
        )
        #expect(patch.contains("new file mode 100755"))
        #expect(!patch.contains("new file mode 100644"))
    }

    @Test func emitsNoTrailingNewlineSentinelAfterAffectedLines() {
        // Mark both the delete and add as missing their trailing newline.
        // The builder must re-emit the `\ No newline at end of file` marker
        // immediately after each affected line; without it `git apply`
        // rejects the patch for EOF-without-newline files.
        let delLine = ParsedDiff.Hunk.Line(
            kind: .delete, text: "old", oldNumber: 1, newNumber: nil,
            noTrailingNewline: true
        )
        let addLine = ParsedDiff.Hunk.Line(
            kind: .add, text: "new", oldNumber: nil, newNumber: 1,
            noTrailingNewline: true
        )
        let h = hunk("@@ -1,1 +1,1 @@", [delLine, addLine])
        let patch = HunkPatchBuilder.patch(file: "a.txt", hunk: h, tracked: true)
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Header (4) + delete + sentinel + add + sentinel + trailing empty.
        #expect(lines[4] == "-old")
        #expect(lines[5] == "\\ No newline at end of file")
        #expect(lines[6] == "+new")
        #expect(lines[7] == "\\ No newline at end of file")
    }
}
