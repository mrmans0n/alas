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
        #expect(replacement.old?.anchor == DiffLineAnchor(filePath: "Sources/Foo.swift", side: .old, oldLine: 11, newLine: nil))
        #expect(replacement.new?.anchor == DiffLineAnchor(filePath: "Sources/Foo.swift", side: .new, oldLine: nil, newLine: 11))
        #expect(replacement.old?.inlineSpans.map { $0.text(in: replacement.old?.text ?? "") } == ["\"unified\""])
        #expect(replacement.new?.inlineSpans.map { $0.text(in: replacement.new?.text ?? "") } == ["layout"])
    }

    @Test func preservesHunkForActions() {
        let diff = sampleDiff()
        let model = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/Foo.swift")
        #expect(model.groups[0].sourceHunk == diff.hunks[0])
    }

    @Test func collapsesLargeContextRunsInsideHunk() {
        let context = (1...12).map {
            ParsedDiff.Hunk.Line(kind: .context, text: "line \($0)", oldNumber: $0, newNumber: $0)
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

    @Test func selectionRangeNormalizesAnchorOrder() {
        let a = DiffLineAnchor(filePath: "a.txt", side: .new, oldLine: nil, newLine: 4)
        let b = DiffLineAnchor(filePath: "a.txt", side: .new, oldLine: nil, newLine: 2)
        let range = DiffSelectionRange(first: a, last: b)
        #expect(range.normalized.lowerBound == b)
        #expect(range.normalized.upperBound == a)
    }
}
