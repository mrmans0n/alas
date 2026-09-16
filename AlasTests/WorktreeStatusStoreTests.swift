import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct WorktreeStatusStoreTests {
    private func freshStore() -> WorktreeStatusStore {
        let store = WorktreeStatusStore.shared
        store.prune(keepingPaths: [])
        return store
    }

    @Test func unseenPathIsUnknownNotClean() {
        // The distinction that keeps the first paint honest.
        #expect(freshStore().status(forPath: "/nope") == .unknown)
    }

    @Test func applyMergesRatherThanReplaces() {
        let store = freshStore()
        store.apply(["/a": .clean, "/b": .dirty(fileCount: 2, conflictCount: 0)])
        // A later partial scan covering only /a must not blank /b.
        store.apply(["/a": .dirty(fileCount: 1, conflictCount: 0)])
        #expect(store.status(forPath: "/a") == .dirty(fileCount: 1, conflictCount: 0))
        #expect(store.status(forPath: "/b") == .dirty(fileCount: 2, conflictCount: 0))
    }

    @Test func applyIgnoresAnEmptyScan() {
        let store = freshStore()
        store.apply(["/a": .clean])
        store.apply([:])
        #expect(store.status(forPath: "/a") == .clean)
    }

    @Test func pruneDropsPathsThatAreGone() {
        let store = freshStore()
        store.apply(["/a": .clean, "/b": .clean])
        store.prune(keepingPaths: ["/a"])
        #expect(store.status(forPath: "/a") == .clean)
        #expect(store.status(forPath: "/b") == .unknown)
    }

    @Test func pruneKeepingEverythingChangesNothing() {
        let store = freshStore()
        store.apply(["/a": .clean, "/b": .clean])
        store.prune(keepingPaths: ["/a", "/b"])
        #expect(store.statuses.count == 2)
    }
}
