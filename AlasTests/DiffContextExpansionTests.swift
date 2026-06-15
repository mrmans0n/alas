import Testing
@testable import Alas

struct DiffContextExpansionTests {
    private func group() -> DiffDisplayGroup {
        let hunk = ParsedDiff.Hunk(
            header: "@@ -4,3 +4,3 @@",
            oldStart: 4,
            newStart: 4,
            lines: [
                .init(kind: .context, text: "old/new 4", oldNumber: 4, newNumber: 4),
                .init(kind: .delete, text: "old 5", oldNumber: 5, newNumber: nil),
                .init(kind: .add, text: "new 5", oldNumber: nil, newNumber: 5),
                .init(kind: .context, text: "old/new 6", oldNumber: 6, newNumber: 6),
            ]
        )
        return DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [hunk]), filePath: "a.swift").groups[0]
    }

    private func snapshot() -> DiffReviewFileContextSnapshot {
        DiffReviewFileContextSnapshot(
            old: .available((1...10).map { "old \($0)" }),
            new: .available((1...12).map { "new \($0)" })
        )
    }

    @Test func derivesAboveBoundaryAndChunkedRows() throws {
        let base = group()
        let snapshot = snapshot()
        var state = DiffContextExpansionState()

        let initial = DiffContextExpandedDisplayBuilder.derive(
            groups: [base],
            snapshot: snapshot,
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )
        #expect(initial[0].rows.first?.contextExpansion?.boundary == .above)
        #expect(initial[0].rows.first?.collapsedLineCount == 3)

        state.expand(.init(groupID: base.id, boundary: .above), available: 3, mode: .chunk(size: 2))
        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: [base],
            snapshot: snapshot,
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )
        #expect(expanded[0].rows.prefix(3).map(\.kind) == [.expandedContext, .expandedContext, .expandableContext])
        #expect(expanded[0].rows[0].old?.lineNumber == 2)
        #expect(expanded[0].rows[1].old?.lineNumber == 3)
        #expect(expanded[0].rows[0].new?.lineNumber == 2)
        #expect(expanded[0].rows[1].new?.lineNumber == 3)
    }

    @Test func optionExpansionRevealsAllBelowBoundary() {
        let base = group()
        var state = DiffContextExpansionState()
        state.expand(.init(groupID: base.id, boundary: .below), available: 6, mode: .all)

        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: [base],
            snapshot: snapshot(),
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )
        let trailing = expanded[0].rows.suffix(6)
        #expect(trailing.allSatisfy { $0.kind == .expandedContext })
        #expect(trailing.first?.old?.lineNumber == 7)
        #expect(trailing.last?.new?.lineNumber == 12)
        #expect(expanded[0].rows.contains { $0.contextExpansion?.boundary == .below } == false)
    }

    @Test func expansionStopsAtAdjacentHunkBoundaries() {
        let first = group()
        let secondHunk = ParsedDiff.Hunk(header: "@@ -8,1 +8,1 @@", oldStart: 8, newStart: 8, lines: [
            .init(kind: .context, text: "line 8", oldNumber: 8, newNumber: 8),
        ])
        let second = DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [secondHunk]), filePath: "a.swift").groups[0]
        var state = DiffContextExpansionState()
        state.expand(.init(groupID: first.id, boundary: .below), available: 10, mode: .all)

        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: [first, second],
            snapshot: snapshot(),
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )

        let firstTrailingContext = expanded[0].rows.filter { $0.kind == .expandedContext }
        #expect(firstTrailingContext.map { $0.old?.lineNumber } == [7])
        #expect(firstTrailingContext.map { $0.new?.lineNumber } == [7])
    }

    @Test func addOnlyExpansionPairsBelowContextBeforeAdjacentHunk() {
        let insertHunk = ParsedDiff.Hunk(header: "@@ -4,0 +5,2 @@", oldStart: 4, newStart: 5, lines: [
            .init(kind: .add, text: "new 5", oldNumber: nil, newNumber: 5),
            .init(kind: .add, text: "new 6", oldNumber: nil, newNumber: 6),
        ])
        let adjacentHunk = ParsedDiff.Hunk(header: "@@ -7,1 +9,1 @@", oldStart: 7, newStart: 9, lines: [
            .init(kind: .context, text: "line", oldNumber: 7, newNumber: 9),
        ])
        let model = DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [insertHunk, adjacentHunk]), filePath: "a.swift")
        var state = DiffContextExpansionState()
        state.expand(.init(groupID: model.groups[0].id, boundary: .below), available: 2, mode: .all)

        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: model.groups,
            snapshot: snapshot(),
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )

        let insertedTrailingContext = expanded[0].rows.filter { $0.kind == .expandedContext }
        #expect(insertedTrailingContext.map { $0.old?.lineNumber } == [5, 6])
        #expect(insertedTrailingContext.map { $0.new?.lineNumber } == [7, 8])
    }

    @Test func deleteOnlyExpansionPairsAboveContextFromHunkPosition() {
        let deleteHunk = ParsedDiff.Hunk(header: "@@ -5,2 +4,0 @@", oldStart: 5, newStart: 4, lines: [
            .init(kind: .delete, text: "old 5", oldNumber: 5, newNumber: nil),
            .init(kind: .delete, text: "old 6", oldNumber: 6, newNumber: nil),
        ])
        let base = DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [deleteHunk]), filePath: "a.swift").groups[0]
        var state = DiffContextExpansionState()
        state.expand(.init(groupID: base.id, boundary: .above), available: 4, mode: .all)

        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: [base],
            snapshot: snapshot(),
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )

        let leadingContext = expanded[0].rows.filter { $0.kind == .expandedContext }
        #expect(leadingContext.map { $0.old?.lineNumber } == [1, 2, 3, 4])
        #expect(leadingContext.map { $0.new?.lineNumber } == [1, 2, 3, 4])
    }

    @Test func originalDiffAnchorsStayStableAfterExpansion() throws {
        let base = group()
        var state = DiffContextExpansionState()
        state.expand(.init(groupID: base.id, boundary: .above), available: 3, mode: .all)

        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: [base],
            snapshot: snapshot(),
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )
        let replacement = try #require(expanded[0].rows.first { $0.kind == .replacement })
        #expect(replacement.old?.anchor == base.rows.first { $0.kind == .replacement }?.old?.anchor)
        #expect(replacement.new?.anchor == base.rows.first { $0.kind == .replacement }?.new?.anchor)
    }
}
