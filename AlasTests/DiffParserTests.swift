import Testing
@testable import Alas

struct DiffParserTests {
    @Test func parsesSingleHunk() throws {
        let raw = """
        diff --git a/src/foo.rs b/src/foo.rs
        index abc..def 100644
        --- a/src/foo.rs
        +++ b/src/foo.rs
        @@ -10,3 +10,4 @@ pub struct Foo {
             let a = 1;
        -    let b = 2;
        +    let b = 3;
        +    let c = 4;
             return a + b;
        """
        let diff = DiffParser.parse(raw)
        #expect(diff.hunks.count == 1)
        let hunk = diff.hunks[0]
        #expect(hunk.header.contains("@@ -10,3 +10,4 @@"))
        #expect(hunk.lines.contains(where: { $0.kind == .delete && $0.text.contains("let b = 2") }))
        #expect(hunk.lines.contains(where: { $0.kind == .add && $0.text.contains("let c = 4") }))
    }

    @Test func emptyDiff() {
        let diff = DiffParser.parse("")
        #expect(diff.hunks.isEmpty)
    }

    @Test func capturesNoTrailingNewlineOnDeleteAndAddSides() {
        // git diff shape for a one-line modification at EOF where both the
        // pre- and post-image lack a trailing newline. The `\ No newline...`
        // sentinel follows each side's content line.
        let raw = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let diff = DiffParser.parse(raw)
        #expect(diff.hunks.count == 1)
        let lines = diff.hunks[0].lines
        #expect(lines.count == 2)
        #expect(lines[0].kind == .delete && lines[0].noTrailingNewline)
        #expect(lines[1].kind == .add && lines[1].noTrailingNewline)
    }
}
