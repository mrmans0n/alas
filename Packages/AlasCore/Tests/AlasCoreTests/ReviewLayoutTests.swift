import AlasRemoteKit
import Testing

struct ReviewLayoutTests {
    private static let id = ReviewEntryID(namespace: "unstaged", path: "a.swift")
    private static let hunks = [
        RemoteDiffHunk(header: "@@ -1,2 +1,2 @@", oldStart: 1, newStart: 1, lines: [
            RemoteDiffLine(kind: "context", text: "a", oldNumber: 1, newNumber: 1),
            RemoteDiffLine(kind: "add", text: "b", oldNumber: nil, newNumber: 2),
        ]),
        RemoteDiffHunk(header: "@@ -9 +9 @@", oldStart: 9, newStart: 9, lines: [
            RemoteDiffLine(kind: "delete", text: "c", oldNumber: 9, newNumber: nil),
        ]),
    ]

    private static func entry(_ content: ReviewEntryContent) -> ReviewEntry {
        ReviewEntry(id: id, status: "M", add: 1, del: 1, renameFrom: nil, content: content)
    }

    private static let cases: [(ReviewEntry, Bool, [ReviewRow])] = [
        (entry(.hunks(hunks, truncated: false)), true, []),
        (entry(.notLoaded), false, [.placeholder(entry: id)]),
        (entry(.loading), false, [.placeholder(entry: id)]),
        (entry(.note("Binary file")), false, [.note(entry: id, text: "Binary file")]),
        (entry(.hunks([], truncated: false)), false, [.note(entry: id, text: "No changes to show")]),
        (entry(.hunks(hunks, truncated: false)), false, [
            .hunkHeader(entry: id, hunk: 0), .line(entry: id, hunk: 0, line: 0), .line(entry: id, hunk: 0, line: 1),
            .hunkHeader(entry: id, hunk: 1), .line(entry: id, hunk: 1, line: 0),
        ]),
        (entry(.hunks([hunks[1]], truncated: true)), false, [
            .hunkHeader(entry: id, hunk: 0), .line(entry: id, hunk: 0, line: 0),
            .note(entry: id, text: "Diff truncated on the Mac"),
        ]),
    ]

    @Test(arguments: cases)
    func rowsForEachKindOfFile(entry: ReviewEntry, folded: Bool, expected: [ReviewRow]) {
        #expect(ReviewLayout.rows(for: entry, folded: folded) == expected)
    }

    @Test(arguments: [
        ("Package.resolved", 1, 1, true), ("Mobile/x/package-lock.json", 1, 1, true),
        ("yarn.lock", 1, 1, true), ("pnpm-lock.yaml", 1, 1, true), ("Cargo.lock", 1, 1, true),
        ("Podfile.lock", 1, 1, true), ("Gemfile.lock", 1, 1, true), ("go.sum", 1, 1, true),
        ("poetry.lock", 1, 1, true), ("Alas.xcodeproj/project.pbxproj", 1, 1, true),
        ("Sources/Big.swift", 1000, 501, true), ("Sources/App.swift", 10, 2, false),
    ])
    func largeAndGeneratedFilesStartFolded(path: String, add: Int, del: Int, folded: Bool) {
        #expect(ReviewLayout.startsFolded(path: path, add: add, del: del) == folded)
    }

    /// Pill 30 tall, the visible band 100...600.
    @Test(arguments: [
        (300.0, 340.0, 266.0), // Room above the selection: there, clear of it and the lines after it.
        (110.0, 150.0, 154.0), // No room above: under the last line.
        (110.0, 590.0, 562.0), // Under would sink behind the action bar: held above the visible bottom.
    ])
    func selectionPillAvoidsTheSelectionAndTheActionBar(top: Double, bottom: Double, expected: Double) {
        #expect(ReviewLayout.selectionPillY(selectionTop: top, selectionBottom: bottom, pillHeight: 30,
                                            visibleTop: 100, visibleBottom: 600) == expected)
    }

    @Test
    func viewedMarkClearsWhenTheDiffChanges() {
        let changed = [RemoteDiffHunk(header: "@@ -1,2 +1,2 @@", oldStart: 1, newStart: 1, lines: [
            RemoteDiffLine(kind: "context", text: "a", oldNumber: 1, newNumber: 1),
            RemoteDiffLine(kind: "add", text: "B", oldNumber: nil, newNumber: 2),
        ]), Self.hunks[1]]
        var marks = ReviewViewedMarks()
        marks.mark(Self.id, hunks: Self.hunks)
        #expect(marks.isViewed(Self.id, hunks: Self.hunks))
        #expect(!marks.isViewed(Self.id, hunks: changed))
        #expect(ReviewViewedMarks(stored: marks.stored).isViewed(Self.id, hunks: Self.hunks))
        marks.unmark(Self.id)
        #expect(!marks.isViewed(Self.id, hunks: Self.hunks))
    }

    private static func line(_ kind: String, old: Int? = nil, new: Int? = nil, text: String = "x") -> RemoteDiffLine {
        RemoteDiffLine(kind: kind, text: text, oldNumber: old, newNumber: new)
    }

    private static let selectionCases: [([RemoteDiffLine], RemoteReviewAnchor)] = [
        ([line("add", new: 42)], .line(side: "new", startLine: 42, endLine: nil, selectedText: "x")),
        ([line("add", new: 42), line("add", new: 43)], .line(side: "new", startLine: 42, endLine: 43, selectedText: "x\nx")),
        ([line("delete", old: 10), line("delete", old: 11)], .line(side: "old", startLine: 10, endLine: 11, selectedText: "x\nx")),
        (
            [line("delete", old: 10, text: "gone"), line("add", new: 10), line("add", new: 11)],
            .line(side: "new", startLine: 10, endLine: 11, selectedText: "x\nx")
        ),
        (
            [line("context", old: 5, new: 5), line("context", old: 6, new: 6), line("context", old: 7, new: 7)],
            .line(side: "new", startLine: 5, endLine: 7, selectedText: "x\nx\nx")
        ),
    ]

    @Test(arguments: selectionCases)
    func selectionAnchorsToOneSide(lines: [RemoteDiffLine], expected: RemoteReviewAnchor) {
        let hunk = RemoteDiffHunk(header: "@@", oldStart: 1, newStart: 1, lines: lines)
        var selection = ReviewSelection(entry: Self.id, hunk: 0, line: 0)
        selection.extend(to: lines.count - 1, inHunk: 0)
        #expect(selection.anchor(in: hunk) == expected)
    }

    @Test
    func extendingStaysInItsHunk() {
        var selection = ReviewSelection(entry: Self.id, hunk: 0, line: 3)
        selection.extend(to: 9, inHunk: 1)
        #expect((selection.start, selection.end) == (3, 3))
        selection.extend(to: 1, inHunk: 0)
        #expect((selection.start, selection.end) == (1, 3))
        var drag = ReviewSelection(entry: Self.id, hunk: 0, line: 10)
        drag.extend(to: 15, inHunk: 0)
        drag.extend(to: 12, inHunk: 0)
        #expect((drag.start, drag.end) == (10, 12))
        drag.extend(to: 8, inHunk: 0)
        #expect((drag.start, drag.end) == (8, 10))
    }

    @Test
    func selectionDropsWhenItsLinesAreGone() {
        var selection = ReviewSelection(entry: Self.id, hunk: 0, line: 0)
        selection.extend(to: 1, inHunk: 0)
        #expect(selection.isValid(in: Self.hunks))
        selection.extend(to: 2, inHunk: 0)
        #expect(!selection.isValid(in: Self.hunks))
        #expect(!ReviewSelection(entry: Self.id, hunk: 2, line: 0).isValid(in: Self.hunks))
    }

    @Test
    func quotedTextPrefixesEachLineBySign() {
        let hunk = Self.hunks[0]
        var selection = ReviewSelection(entry: Self.id, hunk: 0, line: 0)
        selection.extend(to: 1, inHunk: 0)
        #expect(selection.quotedText(in: hunk) == "  a\n+ b")
    }

    private static let commentHunks = [
        RemoteDiffHunk(header: "@@ -10,2 +41,3 @@", oldStart: 10, newStart: 41, lines: [
            RemoteDiffLine(kind: "context", text: "a", oldNumber: 10, newNumber: 41),
            RemoteDiffLine(kind: "add", text: "b", oldNumber: nil, newNumber: 42),
            RemoteDiffLine(kind: "add", text: "c", oldNumber: nil, newNumber: 43),
            RemoteDiffLine(kind: "delete", text: "d", oldNumber: 11, newNumber: nil),
        ]),
    ]

    @Test(arguments: [
        (ReviewPlaceable(id: "a", side: "new", line: 42, endLine: 43), 3),
        (ReviewPlaceable(id: "a", side: "old", line: 10, endLine: nil), 1),
        (ReviewPlaceable(id: "a", side: "new", line: 999, endLine: nil), nil),
        (ReviewPlaceable(id: "a", side: nil, line: nil, endLine: nil), nil),
    ] as [(ReviewPlaceable, Int?)])
    func commentsPlaceUnderTheirLastLine(item: ReviewPlaceable, row: Int?) {
        #expect(ReviewCommentPlacement.place([item], in: Self.commentHunks) == [ReviewPlacedComment(id: "a", row: row)])
    }

    /// Rows: header 0; new lines 1 "a" (40), 2 "b" (41), 3 "keep" (42), 4 "a" (43), 5 "b" (44), 6 "c" (45).
    private static let movedHunks = [
        RemoteDiffHunk(header: "@@ +40,6 @@", oldStart: 1, newStart: 40, lines: ["a", "b", "keep", "a", "b", "c"].enumerated().map {
            RemoteDiffLine(kind: "add", text: $1, oldNumber: nil, newNumber: 40 + $0)
        }),
    ]

    @Test(arguments: [
        // Still reads the same at its anchor, trailing whitespace aside.
        ("keep  ", 42, 42, 3, nil),
        // Its code moved down: the one run that reads it.
        ("b\nc", 10, 11, 6, 44...45),
        // Two runs read it: Outdated.
        ("a\nb", 10, 11, nil, nil),
        // Gone.
        ("zzz", 42, nil, nil, nil),
        // No quote: by line numbers, whatever the code there reads now.
        (nil, 41, nil, 2, nil),
    ] as [(String?, Int, Int?, Int?, ClosedRange<Int>?)])
    func quotedCommentsFollowTheirCode(quote: String?, line: Int, endLine: Int?, row: Int?, movedTo: ClosedRange<Int>?) {
        let item = ReviewPlaceable(id: "a", side: "new", line: line, endLine: endLine, selectedText: quote)
        #expect(ReviewCommentPlacement.place([item], in: Self.movedHunks) == [ReviewPlacedComment(id: "a", row: row, movedTo: movedTo)])
    }

    @Test
    func commentRowsKeepInputOrderAndOutdatedOnesGoToTheTop() {
        let items = [
            ReviewPlaceable(id: "y", side: "new", line: 43, endLine: nil),
            ReviewPlaceable(id: "x", side: "new", line: 43, endLine: nil),
            ReviewPlaceable(id: "z", side: nil, line: nil, endLine: nil),
            ReviewPlaceable(id: "b", side: nil, line: nil, endLine: nil),
        ]
        var placed = ReviewCommentPlacement.place(items, in: Self.commentHunks)
        placed.append(ReviewPlacedComment(id: "late", row: 99))
        let entry = Self.entry(.hunks(Self.commentHunks, truncated: false))
        let rows = ReviewLayout.rows(for: entry, folded: false, comments: placed)
        let id = Self.id
        #expect(rows == [
            .hunkHeader(entry: id, hunk: 0), .comment(entry: id, id: "z"), .comment(entry: id, id: "b"),
            .line(entry: id, hunk: 0, line: 0), .line(entry: id, hunk: 0, line: 1),
            .line(entry: id, hunk: 0, line: 2), .comment(entry: id, id: "y"), .comment(entry: id, id: "x"),
            .line(entry: id, hunk: 0, line: 3), .comment(entry: id, id: "late"),
        ])
        let binary = ReviewLayout.rows(for: Self.entry(.note("Binary file")), folded: false, comments: Array(placed.prefix(2)))
        #expect(binary == [.note(entry: id, text: "Binary file"), .comment(entry: id, id: "y"), .comment(entry: id, id: "x")])
    }

    @Test func pullRequestDiffSplitsIntoEntries() {
        let raw = """
        diff --git a/a.swift b/a.swift
        index 1..2 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
        diff --git a/old.txt b/new.txt
        similarity index 100%
        rename from old.txt
        rename to new.txt
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        diff --git a/img.png b/img.png
        index 1..2 100644
        Binary files a/img.png and b/img.png differ

        """
        let entries = PullRequestDiff.entries(raw: raw, namespace: "github-pr")
        #expect(entries.map(\.id) == ["a.swift", "new.txt", "run.sh", "img.png"].map { ReviewEntryID(namespace: "github-pr", path: $0) })
        #expect(entries.map(\.status) == ["M", "R", "M", "M"])
        #expect(entries[1].renameFrom == "old.txt")
        #expect(entries[0].add == 1 && entries[0].del == 1)
        guard case let .hunks(hunks, truncated) = entries[0].content else { Issue.record("expected hunks")
        return }
        #expect(!truncated && hunks.count == 1)
        #expect(hunks[0].lines.map(\.kind) == ["context", "delete", "add"])
        #expect(hunks[0].lines.map(\.newNumber) == [1, nil, 2])
        #expect(entries[1].content == .note("Renamed from old.txt to new.txt — no content changes."))
        #expect(entries[2].content == .note("File mode changed from 100644 to 100755 — no content changes."))
        #expect(entries[3].content == .note("Binary file"))
        // Only a cut inside the last section's lines marks it: a trailing binary file leaves the rest whole.
        #expect(PullRequestDiff.entries(raw: raw, namespace: "github-pr", truncated: true) == entries)
        let cut = PullRequestDiff.entries(raw: raw.components(separatedBy: "diff --git a/old.txt")[0], namespace: "github-pr", truncated: true)
        #expect(cut.map(\.content) == [.hunks(hunks, truncated: true)])
    }
}
