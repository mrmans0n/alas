import Testing
@testable import Alas

struct ClosedTabHistoryTests {
    private func tab(_ id: String) -> Tab {
        .terminal(.init(id: id, title: id, sessionId: "session-\(id)"))
    }

    private func entry(_ id: String, worktreeID: String = "wt") -> ClosedTabEntry {
        ClosedTabEntry(
            snapshot: .worktree(worktreeID: worktreeID, tab: tab(id)),
            placement: .init(previousID: nil, nextID: nil, ordinal: 0)
        )
    }

    @Test func popsNewestEntryFirst() {
        var history = ClosedTabHistory()
        history.record(entry("a"))
        history.record(entry("b"))

        #expect(history.last?.snapshot.tabID == "b")
        history.remove(id: history.last!.id)
        #expect(history.last?.snapshot.tabID == "a")
    }

    @Test func retainsOnlyFiftyNewestEntries() {
        var history = ClosedTabHistory()
        for index in 0..<51 { history.record(entry("tab-\(index)")) }

        #expect(history.count == 50)
        #expect(history.entries.first?.snapshot.tabID == "tab-1")
        #expect(history.last?.snapshot.tabID == "tab-50")
    }

    @Test func removesBulkEntriesInReverseVisibleOrder() {
        var history = ClosedTabHistory()
        history.record(contentsOf: [entry("a"), entry("c"), entry("d")])

        #expect(history.last?.snapshot.tabID == "d")
        history.remove(id: history.last!.id)
        #expect(history.last?.snapshot.tabID == "c")
        history.remove(id: history.last!.id)
        #expect(history.last?.snapshot.tabID == "a")
    }

    @Test func placementPrefersNextThenPreviousThenOrdinal() {
        let beforeC = ClosedTabPlacement(previousID: "a", nextID: "c", ordinal: 1)
        #expect(beforeC.insertionIndex(in: ["a", "c"]) == 1)
        #expect(beforeC.insertionIndex(in: ["a", "d"]) == 1)
        #expect(beforeC.insertionIndex(in: ["d"]) == 1)
        #expect(beforeC.insertionIndex(in: []) == 0)
    }

    @Test func placementReconstructsOriginalOrderFromOneSurvivingTab() {
        let placements = [
            "a": ClosedTabPlacement(previousID: nil, nextID: "b", ordinal: 0),
            "c": ClosedTabPlacement(previousID: "b", nextID: "d", ordinal: 2),
            "d": ClosedTabPlacement(previousID: "c", nextID: nil, ordinal: 3),
        ]
        var current = ["b"]

        for id in ["a", "c", "d"] {
            current.insert(id, at: placements[id]!.insertionIndex(in: current))
        }

        #expect(current == ["a", "b", "c", "d"])
    }

    @Test func purgeRemovesOnlyMatchingWorktreeEntries() {
        var history = ClosedTabHistory()
        history.record(entry("a", worktreeID: "first"))
        history.record(entry("b", worktreeID: "second"))
        history.purge(worktreeID: "first")

        #expect(history.entries.map(\.snapshot.tabID) == ["b"])
    }

    @Test func replacingLeavesPreservesSplitLayoutAndUnchangedLeaves() {
        let original: PaneNode = .split(PaneSplit(
            id: "root", axis: .vertical, fraction: 0.7,
            children: [
                .leaf(PaneLeaf(id: "old-a", sessionId: "old-a", lastCwd: "/original/a")),
                .split(PaneSplit(
                    id: "inner", axis: .horizontal, fraction: 0.25,
                    children: [
                        .leaf(PaneLeaf(id: "old-b", sessionId: "old-b", lastCwd: "/original/b")),
                        .leaf(PaneLeaf(id: "unchanged", sessionId: "unchanged", lastCwd: "/original/c")),
                    ]
                )),
            ]
        ))
        let replacements = [
            "old-a": PaneLeaf(id: "new-a", sessionId: "new-a", lastCwd: "/restored/a"),
            "old-b": PaneLeaf(id: "new-b", sessionId: "new-b", lastCwd: "/restored/b"),
        ]

        let restored = original.replacingLeaves(using: replacements)

        guard case .split(let root) = restored,
              case .leaf(let first) = root.children[0],
              case .split(let inner) = root.children[1],
              case .leaf(let second) = inner.children[0],
              case .leaf(let third) = inner.children[1] else {
            Issue.record("expected the original split layout")
            return
        }
        #expect(root.id == "root")
        #expect(root.axis == .vertical)
        #expect(root.fraction == 0.7)
        #expect(inner.id == "inner")
        #expect(inner.axis == .horizontal)
        #expect(inner.fraction == 0.25)
        #expect([first.id, second.id, third.id] == ["new-a", "new-b", "unchanged"])
        #expect([first.lastCwd, second.lastCwd, third.lastCwd] == ["/restored/a", "/restored/b", "/original/c"])
    }
}
