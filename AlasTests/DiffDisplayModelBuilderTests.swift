import Testing
@testable import Alas

struct DiffDisplayModelBuilderTests {
    private func sampleDiff() -> ParsedDiff {
        ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -10,4 +10,4 @@",
                oldStart: 10,
                newStart: 10,
                lines: [
                    .init(kind: .context, text: "struct Foo {", oldNumber: 10, newNumber: 10),
                    .init(kind: .delete, text: "    let mode = \"unified\"", oldNumber: 11, newNumber: nil),
                    .init(kind: .add, text: "    let mode = layout", oldNumber: nil, newNumber: 11),
                    .init(kind: .context, text: "}", oldNumber: 12, newNumber: 12),
                ]
            )
        ])
    }

    @Test func buildsSplitRowsWithStableAnchors() {
        let model = DiffDisplayModelBuilder.build(diff: sampleDiff(), filePath: "Sources/Foo.swift")
        #expect(model.filePath == "Sources/Foo.swift")
        #expect(model.groups.count == 1)
        #expect(model.groups[0].header == "@@ -10,4 +10,4 @@")
        #expect(model.groups[0].rows.count == 3)

        let replacement = model.groups[0].rows[1]
        #expect(replacement.kind == .replacement)
        #expect(
            replacement.old?.anchor == DiffLineAnchor(
                filePath: "Sources/Foo.swift",
                hunkIndex: 0,
                rowIndex: 1,
                side: .old,
                oldLine: 11,
                newLine: nil
            )
        )
        #expect(
            replacement.new?.anchor == DiffLineAnchor(
                filePath: "Sources/Foo.swift",
                hunkIndex: 0,
                rowIndex: 1,
                side: .new,
                oldLine: nil,
                newLine: 11
            )
        )
        #expect(replacement.old?.inlineSpans.map { $0.text(in: replacement.old?.text ?? "") } == ["\"unified\""])
        #expect(replacement.new?.inlineSpans.map { $0.text(in: replacement.new?.text ?? "") } == ["layout"])
    }

    @Test func preservesHunkForActions() {
        let diff = sampleDiff()
        let model = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/Foo.swift")
        #expect(model.groups[0].sourceHunk == diff.hunks[0])
    }

    @Test func collapsesLargeContextRunsInsideHunk() {
        let context = (1...12).map { (number: Int) in
            ParsedDiff.Hunk.Line(kind: .context, text: "line \(number)", oldNumber: number, newNumber: number)
        }
        let hunk = ParsedDiff.Hunk(header: "@@ -1,12 +1,12 @@", oldStart: 1, newStart: 1, lines: context)
        let model = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [hunk]),
            filePath: "a.txt",
            collapseContextThreshold: 6,
            contextEdgeCount: 2
        )

        let rows = model.groups[0].rows
        #expect(rows.map(\.kind) == [.context, .context, .collapsed, .context, .context])
        #expect(rows[2].collapsedLineCount == 8)
    }

    @Test func contextAnchorsRemainStableAcrossCollapsedAndExpandedBuilds() throws {
        let context = (1...12).map { (number: Int) in
            ParsedDiff.Hunk.Line(kind: .context, text: "line \(number)", oldNumber: number, newNumber: number)
        }
        let hunk = ParsedDiff.Hunk(header: "@@ -1,12 +1,12 @@", oldStart: 1, newStart: 1, lines: context)
        let collapsed = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [hunk]),
            filePath: "a.txt",
            collapseContextThreshold: 6,
            contextEdgeCount: 2
        )
        let expanded = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [hunk]),
            filePath: "a.txt",
            collapseContextThreshold: 99,
            contextEdgeCount: 2
        )

        func contextAnchors(in model: DiffDisplayModel, text: String) throws -> (old: DiffLineAnchor, new: DiffLineAnchor) {
            let row = try #require(model.groups[0].rows.first { $0.kind == .context && $0.old?.text == text })
            return (old: try #require(row.old?.anchor), new: try #require(row.new?.anchor))
        }

        for text in ["line 1", "line 2", "line 11", "line 12"] {
            let collapsedAnchors = try contextAnchors(in: collapsed, text: text)
            let expandedAnchors = try contextAnchors(in: expanded, text: text)
            #expect(collapsedAnchors.old == expandedAnchors.old)
            #expect(collapsedAnchors.new == expandedAnchors.new)
        }
    }

    @Test func selectionRangeNormalizesAnchorOrder() {
        let a = DiffLineAnchor(filePath: "a.txt", hunkIndex: 0, rowIndex: 4, side: .new, oldLine: nil, newLine: 4)
        let b = DiffLineAnchor(filePath: "a.txt", hunkIndex: 0, rowIndex: 2, side: .new, oldLine: nil, newLine: 2)
        let range = DiffSelectionRange(first: a, last: b)
        #expect(range.normalized.lowerBound == b)
        #expect(range.normalized.upperBound == a)
    }

    @Test func selectionRangeUsesDisplayOrderWhenOldAndNewLineSpacesDiverge() {
        let hunk = ParsedDiff.Hunk(
            header: "@@ -100,3 +10,3 @@",
            oldStart: 100,
            newStart: 10,
            lines: [
                .init(kind: .context, text: "before", oldNumber: 100, newNumber: 10),
                .init(kind: .delete, text: "old value", oldNumber: 101, newNumber: nil),
                .init(kind: .add, text: "new value", oldNumber: nil, newNumber: 11),
                .init(kind: .context, text: "after", oldNumber: 102, newNumber: 12),
            ]
        )

        let model = DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [hunk]), filePath: "a.txt")
        let rows = model.groups[0].rows
        let first = rows[0].old!.anchor
        let replacementOld = rows[1].old!.anchor
        let replacementNew = rows[1].new!.anchor
        let last = rows[2].new!.anchor

        #expect(replacementOld.hunkIndex == replacementNew.hunkIndex)
        #expect(replacementOld.rowIndex == replacementNew.rowIndex)

        let sameRowRange = DiffSelectionRange(first: replacementNew, last: replacementOld)
        #expect(sameRowRange.normalized.lowerBound == replacementOld)
        #expect(sameRowRange.normalized.upperBound == replacementNew)

        let multiRowRange = DiffSelectionRange(first: first, last: last)
        #expect(multiRowRange.normalized.lowerBound == first)
        #expect(multiRowRange.normalized.upperBound == last)
        #expect(multiRowRange.contains(replacementOld))
        #expect(multiRowRange.contains(replacementNew))
    }
}
