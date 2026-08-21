import Foundation
import Testing
@testable import Alas

@MainActor
struct DiffReviewRenderContextCacheTests {
    @Test func evictsLeastRecentlyUsedEntry() {
        let cache = DiffReviewRenderContextCache(limit: 2)
        let a = key(path: "A.swift")
        let b = key(path: "B.swift")
        let c = key(path: "C.swift")

        _ = cache.context(key: a, build: emptyContext)
        _ = cache.context(key: b, build: emptyContext)
        // Touching A makes B the least recently used entry.
        _ = cache.context(key: a, build: emptyContext)
        _ = cache.context(key: c, build: emptyContext)

        let missesBefore = cache.missCountForTests
        _ = cache.context(key: a, build: emptyContext)
        _ = cache.context(key: c, build: emptyContext)
        #expect(cache.missCountForTests == missesBefore)

        // B was evicted, so it has to be rebuilt.
        _ = cache.context(key: b, build: emptyContext)
        #expect(cache.missCountForTests == missesBefore + 1)
    }

    @Test func repeatedHitsDoNotEvict() {
        let cache = DiffReviewRenderContextCache(limit: 2)
        let a = key(path: "A.swift")
        let b = key(path: "B.swift")

        _ = cache.context(key: a, build: emptyContext)
        _ = cache.context(key: b, build: emptyContext)
        for _ in 0..<10 {
            _ = cache.context(key: a, build: emptyContext)
            _ = cache.context(key: b, build: emptyContext)
        }

        #expect(cache.missCountForTests == 2)
    }

    private func emptyContext() -> DiffReviewRenderContext {
        DiffReviewRenderContextBuilder.build(
            fileID: DiffReviewFileID(namespace: "review", path: "A.swift"),
            displayModel: model(path: "A.swift"),
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

    private func key(path: String) -> DiffReviewRenderContextKey {
        DiffReviewRenderContextKey(
            fileID: DiffReviewFileID(namespace: "review", path: path),
            displayModel: model(path: path),
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

    private func model(path: String) -> DiffDisplayModel {
        let hunk = ParsedDiff.Hunk(
            header: "@@ -1,1 +1,1 @@",
            oldStart: 1,
            newStart: 1,
            lines: [.init(kind: .add, text: "let a = 1", oldNumber: nil, newNumber: 1)]
        )
        return DiffDisplayModelBuilder.build(diff: ParsedDiff(hunks: [hunk]), filePath: path)
    }
}
