import Testing
@testable import Alas

@Suite("ACPVisibleRowsCache")
@MainActor
struct ACPVisibleRowsCacheTests {
    @Test("same key returns the cached rows without rebuilding")
    func sameKeyReturnsCachedRowsWithoutRebuilding() {
        let cache = ACPVisibleRowsCache()
        var buildCount = 0
        func build() -> [ACPTranscriptVisibleRow] {
            buildCount += 1
            return [ACPTranscriptVisibleRow(index: 0, stableId: "a")]
        }

        let first = cache.rows(generation: 1, head: 0, tail: 1, build: build)
        let second = cache.rows(generation: 1, head: 0, tail: 1, build: build)

        #expect(buildCount == 1)
        #expect(first == second)
    }

    @Test("bumping the generation rebuilds")
    func bumpingGenerationRebuilds() {
        let cache = ACPVisibleRowsCache()
        var buildCount = 0
        func build() -> [ACPTranscriptVisibleRow] {
            buildCount += 1
            return [ACPTranscriptVisibleRow(index: 0, stableId: "a")]
        }

        _ = cache.rows(generation: 1, head: 0, tail: 1, build: build)
        _ = cache.rows(generation: 2, head: 0, tail: 1, build: build)

        #expect(buildCount == 2)
    }

    @Test("changing the head rebuilds")
    func changingHeadRebuilds() {
        let cache = ACPVisibleRowsCache()
        var buildCount = 0
        func build() -> [ACPTranscriptVisibleRow] {
            buildCount += 1
            return [ACPTranscriptVisibleRow(index: 0, stableId: "a")]
        }

        _ = cache.rows(generation: 1, head: 0, tail: 1, build: build)
        _ = cache.rows(generation: 1, head: 1, tail: 1, build: build)

        #expect(buildCount == 2)
    }

    @Test("changing the tail rebuilds")
    func changingTailRebuilds() {
        let cache = ACPVisibleRowsCache()
        var buildCount = 0
        func build() -> [ACPTranscriptVisibleRow] {
            buildCount += 1
            return [ACPTranscriptVisibleRow(index: 0, stableId: "a")]
        }

        _ = cache.rows(generation: 1, head: 0, tail: 1, build: build)
        _ = cache.rows(generation: 1, head: 0, tail: 2, build: build)

        #expect(buildCount == 2)
    }

    @Test("lookup is memoized alongside rows for the same key")
    func lookupMemoizedForSameKey() {
        let cache = ACPVisibleRowsCache()
        var buildCount = 0
        func build() -> [ACPTranscriptVisibleRow] {
            buildCount += 1
            return [
                ACPTranscriptVisibleRow(index: 0, stableId: "a"),
                ACPTranscriptVisibleRow(index: 1, stableId: "b")
            ]
        }

        _ = cache.lookup(generation: 1, head: 0, tail: 2, build: build)
        let second = cache.lookup(generation: 1, head: 0, tail: 2, build: build)

        #expect(buildCount == 1)
        #expect(second.transcriptIndex(for: "b") == 1)
    }

    @Test("lookup rebuilds when the key changes")
    func lookupRebuildsWhenKeyChanges() {
        let cache = ACPVisibleRowsCache()
        var buildCount = 0
        func build() -> [ACPTranscriptVisibleRow] {
            buildCount += 1
            return [ACPTranscriptVisibleRow(index: buildCount - 1, stableId: "row-\(buildCount)")]
        }

        let first = cache.lookup(generation: 1, head: 0, tail: 1, build: build)
        let second = cache.lookup(generation: 2, head: 0, tail: 1, build: build)

        #expect(buildCount == 2)
        #expect(first.transcriptIndex(for: "row-1") == 0)
        #expect(second.transcriptIndex(for: "row-1") == nil)
        #expect(second.transcriptIndex(for: "row-2") == 1)
    }
}
