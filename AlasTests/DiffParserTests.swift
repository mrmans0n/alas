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

    // MARK: - Exact git patches

    struct ExactPatchCase: Sendable, CustomTestStringConvertible {
        let name: String
        let patch: String
        let path: String
        let change: GitFilePatch.Change
        let oldPath: String?
        let newPath: String?
        let added: Int
        let removed: Int
        let hunkCount: Int
        var testDescription: String { name }
    }

    struct RejectedPatchCase: Sendable, CustomTestStringConvertible {
        let name: String
        let patch: String
        let path: String
        let failure: GitFilePatchFailure
        var testDescription: String { name }
    }

    /// Joins patch lines with `\n` and ends the text with one.
    private static func patch(_ lines: String...) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    /// A one-hunk modification of `repo/a.txt`.
    private static let modifiedA = patch(
        "diff --git a/repo/a.txt b/repo/a.txt",
        "index 1234567..89abcde 100644",
        "--- a/repo/a.txt",
        "+++ b/repo/a.txt",
        "@@ -1 +1 @@",
        "-a",
        "+b"
    )

    static let exactPatchCases: [ExactPatchCase] = [
        ExactPatchCase(
            name: "modified",
            patch: patch(
                "diff --git a/repo/src/a.swift b/repo/src/a.swift",
                "index 1234567..89abcde 100644",
                "--- a/repo/src/a.swift",
                "+++ b/repo/src/a.swift",
                "@@ -2 +2 @@",
                "-old",
                "+new"
            ),
            path: "/repo/src/a.swift", change: .modified,
            oldPath: "repo/src/a.swift", newPath: "repo/src/a.swift", added: 1, removed: 1, hunkCount: 1
        ),
        ExactPatchCase(
            name: "claudeSpaceTab",
            patch: patch(
                "diff --git a/repo/my file.txt b/repo/my file.txt",
                "index 1234567..89abcde 100644",
                "--- a/repo/my file.txt\t",
                "+++ b/repo/my file.txt\t",
                "@@ -1 +1 @@",
                "-a",
                "+b"
            ),
            path: "/repo/my file.txt", change: .modified,
            oldPath: "repo/my file.txt", newPath: "repo/my file.txt", added: 1, removed: 1, hunkCount: 1
        ),
        ExactPatchCase(
            name: "claudeOctal",
            patch: patch(
                #"diff --git "a/repo/caf\303\251.txt" "b/repo/caf\303\251.txt""#,
                "index 1234567..89abcde 100644",
                #"--- "a/repo/caf\303\251.txt""#,
                #"+++ "b/repo/caf\303\251.txt""#,
                "@@ -1 +1 @@",
                "-a",
                "+b"
            ),
            path: "/repo/café.txt", change: .modified,
            oldPath: "repo/café.txt", newPath: "repo/café.txt", added: 1, removed: 1, hunkCount: 1
        ),
        ExactPatchCase(
            name: "codexRawUnicode",
            patch: patch(
                "diff --git a/repo/café.txt b/repo/café.txt",
                "--- a/repo/café.txt",
                "+++ b/repo/café.txt",
                "@@ -1 +1 @@",
                "-a",
                "+b"
            ),
            path: "/repo/café.txt", change: .modified,
            oldPath: "repo/café.txt", newPath: "repo/café.txt", added: 1, removed: 1, hunkCount: 1
        ),
        ExactPatchCase(
            name: "quotedNoTab",
            patch: patch(
                #"diff --git "a/repo/say \"hi\".txt" "b/repo/say \"hi\".txt""#,
                #"--- "a/repo/say \"hi\".txt""#,
                #"+++ "b/repo/say \"hi\".txt""#,
                "@@ -1 +1 @@",
                "-a",
                "+b"
            ),
            path: #"/repo/say "hi".txt"#, change: .modified,
            oldPath: #"repo/say "hi".txt"#, newPath: #"repo/say "hi".txt"#, added: 1, removed: 1, hunkCount: 1
        ),
        ExactPatchCase(
            name: "quotedWithTab",
            patch: patch(
                #"diff --git "a/repo/say \"hi\".txt" "b/repo/say \"hi\".txt""#,
                "index 1234567..89abcde 100644",
                #"--- "a/repo/say \"hi\".txt""# + "\t",
                #"+++ "b/repo/say \"hi\".txt""# + "\t",
                "@@ -1 +1 @@",
                "-a",
                "+b"
            ),
            path: #"/repo/say "hi".txt"#, change: .modified,
            oldPath: #"repo/say "hi".txt"#, newPath: #"repo/say "hi".txt"#, added: 1, removed: 1, hunkCount: 1
        ),
        ExactPatchCase(
            name: "controlEscapes",
            patch: patch(
                #"diff --git "a/repo/x\a\b\v\fy" "b/repo/x\a\b\v\fy""#,
                #"--- "a/repo/x\a\b\v\fy""#,
                #"+++ "b/repo/x\a\b\v\fy""#,
                "@@ -1 +1 @@",
                "-a",
                "+b"
            ),
            path: "/repo/x\u{07}\u{08}\u{0B}\u{0C}y", change: .modified,
            oldPath: "repo/x\u{07}\u{08}\u{0B}\u{0C}y", newPath: "repo/x\u{07}\u{08}\u{0B}\u{0C}y",
            added: 1, removed: 1, hunkCount: 1
        ),
        ExactPatchCase(
            name: "added",
            patch: patch(
                "diff --git a/repo/new.txt b/repo/new.txt",
                "new file mode 100644",
                "index 0000000..1234567",
                "--- /dev/null",
                "+++ b/repo/new.txt",
                "@@ -0,0 +1,2 @@",
                "+a",
                "+b"
            ),
            path: "/repo/new.txt", change: .added,
            oldPath: nil, newPath: "repo/new.txt", added: 2, removed: 0, hunkCount: 1
        ),
        ExactPatchCase(
            name: "deleted",
            patch: patch(
                "diff --git a/repo/gone.txt b/repo/gone.txt",
                "deleted file mode 100644",
                "index 1234567..0000000",
                "--- a/repo/gone.txt",
                "+++ /dev/null",
                "@@ -1,2 +0,0 @@",
                "-a",
                "-b"
            ),
            path: "/repo/gone.txt", change: .deleted,
            oldPath: "repo/gone.txt", newPath: nil, added: 0, removed: 2, hunkCount: 1
        ),
        ExactPatchCase(
            name: "renamed",
            patch: patch(
                "diff --git a/repo/old.txt b/repo/new.txt",
                "similarity index 50%",
                "rename from repo/old.txt",
                "rename to repo/new.txt",
                "index 1234567..89abcde 100644",
                "--- a/repo/old.txt",
                "+++ b/repo/new.txt",
                "@@ -1 +1 @@",
                "-a",
                "+b"
            ),
            path: "/repo/new.txt", change: .renamed,
            oldPath: "repo/old.txt", newPath: "repo/new.txt", added: 1, removed: 1, hunkCount: 1
        ),
        ExactPatchCase(
            name: "twoHunks",
            patch: patch(
                "diff --git a/repo/a.txt b/repo/a.txt",
                "--- a/repo/a.txt",
                "+++ b/repo/a.txt",
                "@@ -2 +2,2 @@ func first()",
                "-old",
                "+new",
                "+more",
                "@@ -10 +11 @@",
                "-x",
                "+y"
            ),
            path: "/repo/a.txt", change: .modified,
            oldPath: "repo/a.txt", newPath: "repo/a.txt", added: 3, removed: 2, hunkCount: 2
        ),
        ExactPatchCase(
            name: "emptyContextLine",
            patch: patch(
                "diff --git a/repo/a.txt b/repo/a.txt",
                "--- a/repo/a.txt",
                "+++ b/repo/a.txt",
                "@@ -1,3 +1,3 @@",
                " a",
                "",
                "-b",
                "+c"
            ),
            path: "/repo/a.txt", change: .modified,
            oldPath: "repo/a.txt", newPath: "repo/a.txt", added: 1, removed: 1, hunkCount: 1
        ),
        ExactPatchCase(
            name: "dashLines",
            patch: patch(
                "diff --git a/repo/a.txt b/repo/a.txt",
                "--- a/repo/a.txt",
                "+++ b/repo/a.txt",
                "@@ -1 +1 @@",
                "--- comment",
                "+++ x"
            ),
            path: "/repo/a.txt", change: .modified,
            oldPath: "repo/a.txt", newPath: "repo/a.txt", added: 1, removed: 1, hunkCount: 1
        ),
    ]

    @Test(arguments: exactPatchCases)
    func exactPatchParses(_ row: ExactPatchCase) throws {
        let parsed = try GitPatchParser.parse(row.patch, path: row.path).get()
        #expect(parsed.change == row.change)
        #expect(parsed.oldPath == row.oldPath)
        #expect(parsed.newPath == row.newPath)
        #expect(parsed.added == row.added)
        #expect(parsed.removed == row.removed)
        #expect(parsed.diff.hunks.count == row.hunkCount)
        #expect(!parsed.diff.isBinary)
        #expect(parsed.diff.metadataSummary == nil)
    }

    @Test func exactPatchNoNewlineMarker() throws {
        let text = Self.patch(
            "diff --git a/repo/a.txt b/repo/a.txt",
            "--- a/repo/a.txt",
            "+++ b/repo/a.txt",
            "@@ -1,2 +1,2 @@",
            " c",
            "-a",
            "\\ No newline at end of file",
            "+b",
            "\\ No newline at end of file"
        )
        let parsed = try GitPatchParser.parse(text, path: "/repo/a.txt").get()
        let lines = try #require(parsed.diff.hunks.first).lines
        #expect(lines.map(\.text) == ["c", "a", "b"])
        #expect(lines.map(\.noTrailingNewline) == [false, true, true])
        #expect(parsed.added == 1)
        #expect(parsed.removed == 1)
    }

    @Test func exactPatchKeepsCarriageReturns() throws {
        let text = "diff --git a/repo/a.txt b/repo/a.txt\n--- a/repo/a.txt\n+++ b/repo/a.txt\n"
            + "@@ -1,2 +1,2 @@\n-a\r\n+b\r\n c\r\n"
        let parsed = try GitPatchParser.parse(text, path: "/repo/a.txt").get()
        let lines = try #require(parsed.diff.hunks.first).lines
        #expect(lines.map(\.text) == ["a\r", "b\r", "c\r"])
        #expect(lines.count == 3)
    }

    static let rejectedPatchCases: [RejectedPatchCase] = [
        RejectedPatchCase(name: "noFinalNewline", patch: String(modifiedA.dropLast()), path: "/repo/a.txt", failure: .truncated),
        RejectedPatchCase(
            name: "shortHunk",
            patch: patch("diff --git a/repo/a.txt b/repo/a.txt", "--- a/repo/a.txt", "+++ b/repo/a.txt", "@@ -1,3 +1,3 @@", " a", " b"),
            path: "/repo/a.txt", failure: .truncated
        ),
        RejectedPatchCase(name: "extraBodyLine", patch: modifiedA + " c\n", path: "/repo/a.txt", failure: .malformedHunk),
        RejectedPatchCase(
            name: "badHeader",
            patch: patch("diff --git a/repo/a.txt b/repo/a.txt", "--- a/repo/a.txt", "+++ b/repo/a.txt", "@@ -a +1 @@", "+b"),
            path: "/repo/a.txt", failure: .malformedHunk
        ),
        RejectedPatchCase(
            name: "overlap",
            patch: patch(
                "diff --git a/repo/a.txt b/repo/a.txt", "--- a/repo/a.txt", "+++ b/repo/a.txt",
                "@@ -1,2 +1,2 @@", " a", " b",
                "@@ -2 +2 @@", "-b", "+c"
            ),
            path: "/repo/a.txt", failure: .malformedHunk
        ),
        RejectedPatchCase(
            name: "wrongOffset",
            patch: patch(
                "diff --git a/repo/a.txt b/repo/a.txt", "--- a/repo/a.txt", "+++ b/repo/a.txt",
                "@@ -1 +1,2 @@", "-a", "+b", "+c",
                "@@ -5 +5 @@", "-x", "+y"
            ),
            path: "/repo/a.txt", failure: .malformedHunk
        ),
        RejectedPatchCase(
            name: "zeroStartWithLines",
            patch: patch("diff --git a/repo/a.txt b/repo/a.txt", "--- a/repo/a.txt", "+++ b/repo/a.txt", "@@ -0,1 +1 @@", "-a", "+b"),
            path: "/repo/a.txt", failure: .malformedHunk
        ),
        RejectedPatchCase(
            name: "badMarker",
            patch: patch("diff --git a/repo/a.txt b/repo/a.txt", "--- a/repo/a.txt", "+++ b/repo/a.txt", "@@ -1 +1 @@", "-a", "\\ nope", "+b"),
            path: "/repo/a.txt", failure: .malformedHunk
        ),
        RejectedPatchCase(
            name: "secondFile",
            patch: modifiedA + patch("diff --git a/repo/b.txt b/repo/b.txt", "--- a/repo/b.txt", "+++ b/repo/b.txt", "@@ -1 +1 @@", "-a", "+b"),
            path: "/repo/a.txt", failure: .malformedHunk
        ),
        RejectedPatchCase(
            name: "notDiffGit",
            patch: patch("--- a/repo/a.txt", "+++ b/repo/a.txt", "@@ -1 +1 @@", "-a", "+b"),
            path: "/repo/a.txt", failure: .malformedHeader
        ),
        RejectedPatchCase(
            name: "copyFrom",
            patch: patch(
                "diff --git a/repo/b.txt b/repo/a.txt", "similarity index 90%", "copy from repo/b.txt", "copy to repo/a.txt",
                "--- a/repo/b.txt", "+++ b/repo/a.txt", "@@ -1 +1 @@", "-a", "+b"
            ),
            path: "/repo/a.txt", failure: .malformedHeader
        ),
        RejectedPatchCase(
            name: "devNullWithoutMode",
            patch: patch("diff --git a/repo/a.txt b/repo/a.txt", "--- /dev/null", "+++ b/repo/a.txt", "@@ -0,0 +1 @@", "+a"),
            path: "/repo/a.txt", failure: .malformedHeader
        ),
        RejectedPatchCase(
            name: "renameDisagrees",
            patch: patch(
                "diff --git a/repo/old.txt b/repo/a.txt", "rename from repo/old.txt", "rename to repo/a.txt",
                "--- a/repo/other.txt", "+++ b/repo/a.txt", "@@ -1 +1 @@", "-a", "+b"
            ),
            path: "/repo/a.txt", failure: .malformedHeader
        ),
        RejectedPatchCase(
            name: "diffGitDisagrees",
            patch: patch("diff --git a/repo/b.txt b/repo/b.txt", "--- a/repo/a.txt", "+++ b/repo/a.txt", "@@ -1 +1 @@", "-a", "+b"),
            path: "/repo/a.txt", failure: .malformedHeader
        ),
        RejectedPatchCase(
            name: "unterminatedQuote",
            patch: patch("diff --git a/repo/a.txt b/repo/a.txt", #"--- "a/repo/a.txt"#, "+++ b/repo/a.txt", "@@ -1 +1 @@", "-a", "+b"),
            path: "/repo/a.txt", failure: .malformedPath
        ),
        RejectedPatchCase(
            name: "otherPath",
            patch: patch("diff --git a/repo/other.txt b/repo/other.txt", "--- a/repo/other.txt", "+++ b/repo/other.txt", "@@ -1 +1 @@", "-a", "+b"),
            path: "/repo/a.txt", failure: .pathMismatch
        ),
        RejectedPatchCase(
            name: "headersOnly",
            patch: patch("diff --git a/repo/a.txt b/repo/a.txt", "index 1234567..89abcde 100644", "--- a/repo/a.txt", "+++ b/repo/a.txt"),
            path: "/repo/a.txt", failure: .noHunks
        ),
    ]

    @Test(arguments: rejectedPatchCases)
    func exactPatchRejects(_ row: RejectedPatchCase) {
        #expect(GitPatchParser.parse(row.patch, path: row.path) == .failure(row.failure))
    }
}
