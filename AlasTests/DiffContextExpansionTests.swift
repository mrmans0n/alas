import Foundation
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

    private func twoSeparatedGroups() -> [DiffDisplayGroup] {
        let first = group()
        let secondHunk = ParsedDiff.Hunk(header: "@@ -9,1 +9,1 @@", oldStart: 9, newStart: 9, lines: [
            .init(kind: .context, text: "line 9", oldNumber: 9, newNumber: 9),
        ])
        let second = DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [secondHunk]), filePath: "a.swift").groups[0]
        return [first, second]
    }

    @Test func sharedBoundaryTracksExpansionFromBothSides() {
        let key = DiffContextExpansionKey.shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1")
        var state = DiffContextExpansionState()

        state.expand(key, available: 5, mode: .chunk(size: 2), edge: .top)
        state.expand(key, available: 5, mode: .chunk(size: 2), edge: .bottom)

        #expect(state.expandedLineCount(for: key, edge: .top) == 2)
        #expect(state.expandedLineCount(for: key, edge: .bottom) == 2)
        #expect(state.remainingLineCount(for: key, available: 5) == 1)
    }

    @Test func sharedBoundaryExpansionClampsWhenEdgesMeet() {
        let key = DiffContextExpansionKey.shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1")
        var state = DiffContextExpansionState()

        state.expand(key, available: 3, mode: .chunk(size: 2), edge: .top)
        state.expand(key, available: 3, mode: .chunk(size: 2), edge: .bottom)

        #expect(state.expandedLineCount(for: key, edge: .top) == 2)
        #expect(state.expandedLineCount(for: key, edge: .bottom) == 1)
        #expect(state.remainingLineCount(for: key, available: 3) == 0)
    }

    @Test func sharedBoundaryLegacyExpansionAccessReadsTopEdge() {
        let key = DiffContextExpansionKey.shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1")
        var state = DiffContextExpansionState()

        state.expand(key, available: 5, mode: .chunk(size: 2))

        #expect(state.expandedLineCount(for: key) == 2)
        #expect(state.expandedLineCount(for: key, edge: .top) == 2)
        #expect(state.expandedLineCount(for: key, edge: .bottom) == 0)
    }

    @Test func edgeAwareExpansionDelegatesExternalKeysToBoundaryState() {
        let key = DiffContextExpansionKey(groupID: "hunk-0", boundary: .below)
        var state = DiffContextExpansionState()

        state.expand(key, available: 5, mode: .chunk(size: 2), edge: .top)

        #expect(state.expandedLineCount(for: key) == 2)
        #expect(state.expandedLineCount(for: key, edge: .top) == 2)
        #expect(state.remainingLineCount(for: key, available: 5) == 3)
    }

    @Test func decodesLegacyExternalExpansionKeyShape() throws {
        let data = try #require("""
        {"groupID":"hunk-0","boundary":"above"}
        """.data(using: .utf8))

        let key = try JSONDecoder().decode(DiffContextExpansionKey.self, from: data)

        #expect(key == DiffContextExpansionKey(groupID: "hunk-0", boundary: .above))
    }

    @Test func decodesExpansionRowWithoutEdgeUsingBoundaryDefault() throws {
        let data = try #require("""
        {
          "key": {"groupID":"hunk-0","boundary":"above"},
          "boundary": "above",
          "remainingLineCount": 4
        }
        """.data(using: .utf8))

        let row = try JSONDecoder().decode(DiffContextExpansionRow.self, from: data)

        #expect(row.key == DiffContextExpansionKey(groupID: "hunk-0", boundary: .above))
        #expect(row.edge == .bottom)
    }

    @Test func derivesSharedBridgeBetweenNeighboringHunks() throws {
        let groups = twoSeparatedGroups()

        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: groups,
            snapshot: snapshot(),
            providerAvailable: true,
            expansion: DiffContextExpansionState(),
            filePath: "a.swift",
            chunkSize: 2
        )

        let key = DiffContextExpansionKey.shared(upperGroupID: groups[0].id, lowerGroupID: groups[1].id)
        let firstBridge = try #require(expanded[0].rows.compactMap(\.contextExpansion).first { $0.key == key && $0.edge == .top })
        let allBridge = try #require(expanded[0].rows.compactMap(\.contextExpansion).first { $0.key == key && $0.edge == nil })
        let secondBridge = expanded[1].rows.first?.contextExpansion
        #expect(firstBridge.key == key)
        #expect(firstBridge.edge == .top)
        #expect(allBridge.key == key)
        #expect(allBridge.edge == nil)
        #expect(secondBridge?.key == key)
        #expect(secondBridge?.edge == .bottom)
        #expect(expanded[0].sharedContextAfter == nil)
        #expect(expanded[1].sharedContextBefore == nil)
    }

    @Test func sharedBridgeAvailableLineCountUsesInterHunkGap() {
        let groups = twoSeparatedGroups()
        let key = DiffContextExpansionKey.shared(upperGroupID: groups[0].id, lowerGroupID: groups[1].id)

        let available = DiffContextExpandedDisplayBuilder.availableLineCount(
            key: key,
            groups: groups,
            snapshot: snapshot()
        )

        #expect(available == 2)
    }

    @Test func sharedBridgeRevealsFromBothSidesWithoutDuplicatingLines() {
        let groups = twoSeparatedGroups()
        let key = DiffContextExpansionKey.shared(upperGroupID: groups[0].id, lowerGroupID: groups[1].id)
        var state = DiffContextExpansionState()
        state.expand(key, available: 2, mode: .chunk(size: 1), edge: .top)
        state.expand(key, available: 2, mode: .chunk(size: 1), edge: .bottom)

        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: groups,
            snapshot: snapshot(),
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )

        let numbers = expanded.flatMap(\.rows).compactMap { $0.old?.lineNumber }
        #expect(numbers.filter { $0 == 7 }.count == 1)
        #expect(numbers.filter { $0 == 8 }.count == 1)
        #expect(expanded.flatMap(\.rows).contains { $0.contextExpansion?.key == key } == false)
        #expect(expanded[0].sharedContextAfter == key)
        #expect(expanded[1].sharedContextBefore == key)
    }

    @Test func unavailableSharedBridgeContextDoesNotMarkGapExhausted() {
        let groups = twoSeparatedGroups()
        let key = DiffContextExpansionKey.shared(upperGroupID: groups[0].id, lowerGroupID: groups[1].id)
        var state = DiffContextExpansionState()
        state.expand(key, available: 0, mode: .all, edge: .top)
        state.expand(key, available: 0, mode: .all, edge: .bottom)

        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: groups,
            snapshot: DiffReviewFileContextSnapshot(old: .unavailable, new: .unavailable),
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )

        #expect(expanded[0].rows.last?.contextExpansion == nil)
        #expect(expanded[1].rows.first?.contextExpansion == nil)
        #expect(expanded[0].sharedContextAfter == nil)
        #expect(expanded[1].sharedContextBefore == nil)
    }

    @Test func sharedBridgeDoesNotDuplicateShortSideLineWhenGapLengthsDiffer() {
        let firstHunk = ParsedDiff.Hunk(header: "@@ -1,1 +1,1 @@", oldStart: 1, newStart: 1, lines: [
            .init(kind: .context, text: "line 1", oldNumber: 1, newNumber: 1),
        ])
        let secondHunk = ParsedDiff.Hunk(header: "@@ -12,1 +3,1 @@", oldStart: 12, newStart: 3, lines: [
            .init(kind: .context, text: "line end", oldNumber: 12, newNumber: 3),
        ])
        let groups = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [firstHunk, secondHunk]),
            filePath: "a.swift"
        ).groups
        let snapshot = DiffReviewFileContextSnapshot(
            old: .available((1...12).map { "old \($0)" }),
            new: .available((1...3).map { "new \($0)" })
        )
        let key = DiffContextExpansionKey.shared(upperGroupID: groups[0].id, lowerGroupID: groups[1].id)
        var state = DiffContextExpansionState()
        state.expand(key, available: 10, mode: .chunk(size: 1), edge: .top)
        state.expand(key, available: 10, mode: .chunk(size: 9), edge: .bottom)

        let expanded = DiffContextExpandedDisplayBuilder.derive(
            groups: groups,
            snapshot: snapshot,
            providerAvailable: true,
            expansion: state,
            filePath: "a.swift",
            chunkSize: 2
        )

        let newNumbers = expanded.flatMap(\.rows).compactMap { $0.new?.lineNumber }
        #expect(newNumbers.filter { $0 == 2 }.count == 1)
        let oldNumbers = expanded.flatMap(\.rows).compactMap { $0.old?.lineNumber }
        for number in 2...11 {
            #expect(oldNumbers.filter { $0 == number }.count == 1)
        }
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
        #expect(expanded[0].rows.prefix(3).map(\.kind) == [.expandableContext, .expandedContext, .expandedContext])
        #expect(expanded[0].rows[0].contextExpansion?.boundary == .above)
        #expect(expanded[0].rows[0].collapsedLineCount == 1)
        #expect(expanded[0].rows[1].old?.lineNumber == 2)
        #expect(expanded[0].rows[2].old?.lineNumber == 3)
        #expect(expanded[0].rows[1].new?.lineNumber == 2)
        #expect(expanded[0].rows[2].new?.lineNumber == 3)
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
        let key = DiffContextExpansionKey.shared(upperGroupID: first.id, lowerGroupID: second.id)
        state.expand(key, available: 1, mode: .all, edge: .top)

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
        #expect(expanded[1].rows.allSatisfy { $0.contextExpansion?.boundary != .above })
        let allExpandedLineNumbers = expanded.flatMap(\.rows).compactMap { $0.old?.lineNumber }
        #expect(allExpandedLineNumbers.filter { $0 == 7 }.count == 1)
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
        state.expand(
            .shared(upperGroupID: model.groups[0].id, lowerGroupID: model.groups[1].id),
            available: 2,
            mode: .all,
            edge: .top
        )

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
