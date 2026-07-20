import Testing
@testable import Alas

@MainActor
struct GGStackSummaryStoreTests {
    @Test func pruneKeepsOnlyLivePaths() {
        let store = GGStackSummaryStore()
        store.summaries = [
            "/a": GGStackSummary(merged: 1, total: 2),
            "/b": GGStackSummary(merged: 0, total: 1),
        ]
        store.prune(keepingPaths: ["/a"])
        #expect(store.summaries.keys.sorted() == ["/a"])
        // No-op prune leaves the dictionary identity untouched.
        store.prune(keepingPaths: ["/a"])
        #expect(store.summaries.keys.sorted() == ["/a"])
    }
}
