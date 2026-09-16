import Testing
@testable import Alas

@MainActor
struct GGStackSummaryStoreTests {
    private func stack(name: String = "demo", sha: String = "aaa") -> GGStack {
        GGStack(name: name, base: "main", totalCommits: 3, syncedCommits: 2, currentPosition: nil, behindBase: nil, entries: [
            GGStackEntry(position: 1, sha: sha, title: "First", prNumber: 41),
            GGStackEntry(position: 2, sha: "bbb", title: "Second", prNumber: 42),
            GGStackEntry(position: 3, sha: "ccc", title: "Unpublished"),
        ])
    }

    @Test func localTotalIncludesUnpublishedAndWaitsForOnlyItsOwnPRs() throws {
        let store = GGStackSummaryStore()
        let inbox = GGInboxStore()
        store.prepare(path: "/a", projectId: "p", stackName: "demo")
        store.update(path: "/a", projectId: "p", stackName: "demo", stack: stack())
        #expect(store.summary(forPath: "/a", inbox: inbox) == .init(merged: 0, total: 3, isRemoteStateKnown: false))
        let first = GGInboxEntryIdentity(stackName: "demo", sha: "aaa", prNumber: 41)
        let second = GGInboxEntryIdentity(stackName: "demo", sha: "bbb", prNumber: 42)
        inbox.states["p"] = .init(isRefreshing: true, reviewStates: [first: "merged"])
        #expect(store.summary(forPath: "/a", inbox: inbox)?.isRemoteStateKnown == false)
        inbox.states["p"]?.reviewStates[second] = "closed"
        #expect(store.summary(forPath: "/a", inbox: inbox) == .init(merged: 1, total: 3))
        // The global inbox stream is still running on another stack.
        #expect(inbox.states["p"]?.isRefreshing == true)
    }

    @Test func identityFencesOtherProjectsAndRewrittenCommits() {
        let store = GGStackSummaryStore()
        let inbox = GGInboxStore()
        store.prepare(path: "/a", projectId: "p", stackName: "demo")
        store.update(path: "/a", projectId: "p", stackName: "demo", stack: stack(sha: "new"))
        let old = GGInboxEntryIdentity(stackName: "demo", sha: "aaa", prNumber: 41)
        let new = GGInboxEntryIdentity(stackName: "demo", sha: "new", prNumber: 41)
        inbox.states["p"] = .init(reviewStates: [old: "merged"])
        inbox.states["other"] = .init(reviewStates: [new: "merged"])
        #expect(store.summary(forPath: "/a", inbox: inbox)?.merged == 0)
        #expect(store.summary(forPath: "/a", inbox: inbox)?.isRemoteStateKnown == false)
    }

    @Test func legacyRightPaneWritesCannotOverrideManagedInventory() {
        let store = GGStackSummaryStore()
        let inbox = GGInboxStore()
        store.prepare(path: "/a", projectId: "p", stackName: "demo")
        store.update(path: "/a", projectId: "p", stackName: "demo", stack: stack())
        store.summaries["/a"] = .init(merged: 20, total: 20)
        #expect(store.summary(forPath: "/a", inbox: inbox)?.total == 3)
        store.summaries["/a"] = nil
        #expect(store.summary(forPath: "/a", inbox: inbox)?.total == 3)
        store.prepare(path: "/a", projectId: "p", stackName: "different")
        #expect(store.summary(forPath: "/a", inbox: inbox) == nil)
        store.retainManagedPaths([])
        #expect(store.inventories.isEmpty)
    }

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
