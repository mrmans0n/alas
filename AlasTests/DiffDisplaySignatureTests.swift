import Testing
@testable import Alas

struct DiffDisplaySignatureTests {
    private func hunk(
        header: String = "@@ -4,3 +4,3 @@",
        oldStart: Int = 4,
        newStart: Int = 4,
        lines: [ParsedDiff.Hunk.Line]
    ) -> ParsedDiff.Hunk {
        ParsedDiff.Hunk(header: header, oldStart: oldStart, newStart: newStart, lines: lines)
    }

    private func sampleLines() -> [ParsedDiff.Hunk.Line] {
        [
            .init(kind: .context, text: "old/new 4", oldNumber: 4, newNumber: 4),
            .init(kind: .delete, text: "old 5", oldNumber: 5, newNumber: nil),
            .init(kind: .add, text: "new 5", oldNumber: nil, newNumber: 5),
            .init(kind: .context, text: "old/new 6", oldNumber: 6, newNumber: 6),
        ]
    }

    private func model(lines: [ParsedDiff.Hunk.Line]) -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [hunk(lines: lines)]), filePath: "a.swift")
    }

    // MARK: - contentHash

    @Test func contentHashEqualForIdenticalModels() {
        #expect(model(lines: sampleLines()).contentHash == model(lines: sampleLines()).contentHash)
    }

    @Test func contentHashDiffersWhenLineTextChanges() {
        var changed = sampleLines()
        changed[0] = .init(kind: .context, text: "old/new 4 EDITED", oldNumber: 4, newNumber: 4)
        #expect(model(lines: sampleLines()).contentHash != model(lines: changed).contentHash)
    }

    @Test func contentHashDiffersWhenFilePathChanges() {
        let a = DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [hunk(lines: sampleLines())]), filePath: "a.swift")
        let b = DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [hunk(lines: sampleLines())]), filePath: "b.swift")
        #expect(a.contentHash != b.contentHash)
    }

    // MARK: - structuralHash

    @Test func structuralHashEqualForIdenticalModels() {
        #expect(model(lines: sampleLines()).structuralHash == model(lines: sampleLines()).structuralHash)
    }

    @Test func structuralHashIgnoresPureTextEdits() {
        // A text-only edit that keeps line numbers/row structure must not change
        // the structural fingerprint used for state-reset .onChange signals.
        var changed = sampleLines()
        changed[0] = .init(kind: .context, text: "old/new 4 EDITED", oldNumber: 4, newNumber: 4)
        #expect(model(lines: sampleLines()).structuralHash == model(lines: changed).structuralHash)
    }

    @Test func structuralHashDiffersWhenLineNumbersChange() {
        var changed = sampleLines()
        changed[0] = .init(kind: .context, text: "old/new 4", oldNumber: 40, newNumber: 40)
        #expect(model(lines: sampleLines()).structuralHash != model(lines: changed).structuralHash)
    }

    // MARK: - precomputed side extents

    @Test func precomputedSideExtentsMatchConsumedLines() {
        let group = model(lines: sampleLines()).groups[0]
        // old side: context(4) + delete(5) + context(6) = 3 lines starting at 4.
        #expect(group.oldSideExtent.start == 4)
        #expect(group.oldSideExtent.count == 3)
        #expect(group.oldSideExtent.lineBefore == 3)
        #expect(group.oldSideExtent.lineAfter == 7)
        // new side: context(4) + add(5) + context(6) = 3 lines starting at 4.
        #expect(group.newSideExtent.start == 4)
        #expect(group.newSideExtent.count == 3)
    }

    @Test func precomputedSideExtentsHandleEmptySide() {
        let deletionOnly = model(lines: [
            .init(kind: .delete, text: "gone", oldNumber: 5, newNumber: nil),
        ])
        let group = deletionOnly.groups[0]
        #expect(group.newSideExtent.count == 0)
        // With no consumed lines, lineBefore/lineAfter fall back to the start.
        #expect(group.newSideExtent.lineBefore == group.newSideExtent.start)
        #expect(group.newSideExtent.lineAfter == group.newSideExtent.start + 1)
    }

    // MARK: - render context key keys on content hash

    @Test func renderContextKeyEqualForIdenticalModels() {
        let a = model(lines: sampleLines())
        let b = model(lines: sampleLines())
        let fileID = DiffReviewFileID(namespace: "commit", path: "a.swift")
        func key(_ m: DiffDisplayModel) -> DiffReviewRenderContextKey {
            DiffReviewRenderContextKey(
                fileID: fileID,
                displayModel: m,
                contextSnapshot: nil,
                contextProviderAvailable: false,
                contextExpansion: DiffContextExpansionState(),
                inlineFeedback: [],
                draftComments: [],
                pendingDraftAnchor: nil,
                canCreateDraftComment: true,
                threads: [],
                annotations: []
            )
        }
        #expect(key(a) == key(b))
    }

    @Test func renderContextKeyDiffersWhenModelTextChanges() {
        var changed = sampleLines()
        changed[0] = .init(kind: .context, text: "old/new 4 EDITED", oldNumber: 4, newNumber: 4)
        let a = model(lines: sampleLines())
        let b = model(lines: changed)
        let fileID = DiffReviewFileID(namespace: "commit", path: "a.swift")
        func key(_ m: DiffDisplayModel) -> DiffReviewRenderContextKey {
            DiffReviewRenderContextKey(
                fileID: fileID,
                displayModel: m,
                contextSnapshot: nil,
                contextProviderAvailable: false,
                contextExpansion: DiffContextExpansionState(),
                inlineFeedback: [],
                draftComments: [],
                pendingDraftAnchor: nil,
                canCreateDraftComment: true,
                threads: [],
                annotations: []
            )
        }
        #expect(key(a) != key(b))
    }
}
