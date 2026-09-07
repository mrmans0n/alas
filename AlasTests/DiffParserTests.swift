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
        #expect(!diff.isBinary)
    }

    /// A file git classifies as binary (whether by content sniffing or a
    /// `.gitattributes` `binary` declaration) produces no `@@` hunks at
    /// all — just a `Binary files ... differ` line. Without detecting this
    /// explicitly, a hunk-less result is indistinguishable from a
    /// legitimately empty diff.
    @Test func detectsGitsOwnBinaryClassificationLine() {
        let raw = """
        diff --git a/image.dat b/image.dat
        index abc..def 100644
        Binary files a/image.dat and b/image.dat differ
        """
        let diff = DiffParser.parse(raw)
        #expect(diff.hunks.isEmpty)
        #expect(diff.isBinary)
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

    /// A pure rename (100% similarity, no content edits) produces no `@@`
    /// hunks — without `metadataSummary`, the caller would report a
    /// misleadingly "successful" empty diff, indistinguishable from a file
    /// with genuinely no changes at all.
    @Test func pureRenameProducesAMetadataSummary() {
        let raw = """
        diff --git a/old.txt b/new.txt
        similarity index 100%
        rename from old.txt
        rename to new.txt
        """
        let diff = DiffParser.parse(raw)
        #expect(diff.hunks.isEmpty)
        #expect(!diff.isBinary)
        #expect(diff.metadataSummary == "Renamed from old.txt to new.txt — no content changes.")
    }

    /// Same as a pure rename, but for `-C` copy detection (source path
    /// still exists after the copy).
    @Test func pureCopyProducesAMetadataSummary() {
        let raw = """
        diff --git a/old.txt b/new.txt
        similarity index 100%
        copy from old.txt
        copy to new.txt
        """
        let diff = DiffParser.parse(raw)
        #expect(diff.hunks.isEmpty)
        #expect(diff.metadataSummary == "Copied from old.txt to new.txt — no content changes.")
    }

    /// An executable-bit-only change (no rename, no content edits).
    @Test func pureModeChangeProducesAMetadataSummary() {
        let raw = """
        diff --git a/script.sh b/script.sh
        old mode 100644
        new mode 100755
        """
        let diff = DiffParser.parse(raw)
        #expect(diff.hunks.isEmpty)
        #expect(diff.metadataSummary == "File mode changed from 100644 to 100755 — no content changes.")
    }

    /// A rename that ALSO has content edits has real hunks to show — the
    /// summary would just be noise layered over an actual diff, so it must
    /// stay nil here.
    @Test func renameWithContentChangesDoesNotProduceAMetadataSummary() {
        let raw = """
        diff --git a/old.txt b/new.txt
        similarity index 66%
        rename from old.txt
        rename to new.txt
        index abc..def 100644
        --- a/old.txt
        +++ b/new.txt
        @@ -1,3 +1,3 @@
         unchanged
        -removed
        +added
         unchanged
        """
        let diff = DiffParser.parse(raw)
        #expect(!diff.hunks.isEmpty)
        #expect(diff.metadataSummary == nil)
    }
}
