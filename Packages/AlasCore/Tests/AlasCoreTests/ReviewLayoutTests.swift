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
}
