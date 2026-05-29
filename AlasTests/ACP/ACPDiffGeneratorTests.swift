import Foundation
import Testing
@testable import Alas

@Suite("ACPDiffGenerator")
struct ACPDiffGeneratorTests {
    @Test("new file produces all-additions hunk")
    func newFile() async throws {
        let diff = try await ACPDiffGenerator.generate(
            oldText: nil,
            newText: "line1\nline2\nline3\n"
        )
        #expect(diff.hunks.count == 1)
        let hunk = diff.hunks[0]
        #expect(hunk.header == "@@ -0,0 +1,3 @@")
        #expect(hunk.lines.allSatisfy { $0.kind == .add })
        #expect(hunk.lines.count == 3)
        #expect(hunk.lines[0].text == "line1")
        #expect(hunk.lines[0].newNumber == 1)
        #expect(hunk.lines[0].oldNumber == nil)
    }

    @Test("identical texts produce empty diff")
    func identical() async throws {
        let diff = try await ACPDiffGenerator.generate(
            oldText: "abc\ndef\n",
            newText: "abc\ndef\n"
        )
        #expect(diff.hunks.isEmpty)
    }

    @Test("modified file returns hunks from git diff --no-index")
    func modified() async throws {
        let diff = try await ACPDiffGenerator.generate(
            oldText: "alpha\nbeta\ngamma\n",
            newText: "alpha\ndelta\ngamma\n"
        )
        #expect(diff.hunks.count == 1)
        let hunk = diff.hunks[0]
        let adds = hunk.lines.filter { $0.kind == .add }
        let dels = hunk.lines.filter { $0.kind == .delete }
        #expect(adds.contains { $0.text == "delta" })
        #expect(dels.contains { $0.text == "beta" })
    }

    @Test("new file without trailing newline sets noTrailingNewline on last line")
    func newFileNoTrailingNewline() async throws {
        let diff = try await ACPDiffGenerator.generate(
            oldText: nil,
            newText: "line1\nline2\nline3"
        )
        #expect(diff.hunks.count == 1)
        let hunk = diff.hunks[0]
        #expect(hunk.lines.count == 3)
        #expect(hunk.lines.last?.noTrailingNewline == true)
    }

    @Test("new empty file produces empty diff")
    func newEmptyFile() async throws {
        let diff = try await ACPDiffGenerator.generate(
            oldText: nil,
            newText: ""
        )
        #expect(diff.hunks.isEmpty)
    }

    @Test("deleting all content shows deletions")
    func deleteAll() async throws {
        let diff = try await ACPDiffGenerator.generate(
            oldText: "abc\ndef\n",
            newText: ""
        )
        #expect(!diff.hunks.isEmpty)
        let hunk = diff.hunks[0]
        #expect(hunk.lines.allSatisfy { $0.kind == .delete })
    }
}
