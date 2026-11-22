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

    private static func line(_ kind: String, old: Int? = nil, new: Int? = nil) -> RemoteDiffLine {
        RemoteDiffLine(kind: kind, text: "x", oldNumber: old, newNumber: new)
    }

    private static let selectionCases: [([RemoteDiffLine], RemoteReviewAnchor)] = [
        ([line("add", new: 42)], .line(side: "new", startLine: 42, endLine: nil)),
        ([line("add", new: 42), line("add", new: 43)], .line(side: "new", startLine: 42, endLine: 43)),
        ([line("delete", old: 10), line("delete", old: 11)], .line(side: "old", startLine: 10, endLine: 11)),
        (
            [line("delete", old: 10), line("add", new: 10), line("add", new: 11)],
            .line(side: "new", startLine: 10, endLine: 11)
        ),
        (
            [line("context", old: 5, new: 5), line("context", old: 6, new: 6), line("context", old: 7, new: 7)],
            .line(side: "new", startLine: 5, endLine: 7)
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
}
