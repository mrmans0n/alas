import Foundation
import Testing
@testable import Alas

struct WorktreeSidebarFilterTests {
    private func worktree(_ id: String, name: String? = nil, branch: String) -> Worktree {
        Worktree(
            id: id, projectId: "p", name: name ?? branch, branch: branch,
            path: URL(fileURLWithPath: "/tmp/\(id)"), status: .clean, lastActivity: Date()
        )
    }

    @Test(arguments: [
        ("fsf", true),          // fuzzy subsequence across segments
        ("SIDEBAR", true),      // case-insensitive
        ("  side  ", true),     // surrounding whitespace ignored
        ("scratch", true),      // display name, not just branch
        ("zzz", false),
    ])
    func matchesBranchOrNameFuzzily(query: String, expected: Bool) {
        let wt = worktree("a", name: "scratch", branch: "feat/sidebar-filter")
        #expect(WorktreeSidebarFilter.matches(wt, query: query) == expected)
    }

    @Test(arguments: [
        ("flicker", ["fix-flicker"]),               // directory name tells detached worktrees apart
        ("detached", ["fix-flicker", "scratch"]),   // the state still finds all of them
    ])
    func detachedWorktreesMatchByDirectoryName(query: String, expected: [String]) {
        let detached = ["fix-flicker", "scratch"].map { worktree($0, branch: "(detached)") }
        #expect(WorktreeSidebarFilter.apply(query, to: detached).map(\.id) == expected)
    }

    @Test func applyKeepsSortedOrderAndBlankQueryRestoresEverything() {
        let sorted = [
            worktree("1", branch: "fix/login"),
            worktree("2", branch: "main"),
            worktree("3", branch: "feat/logout"),
        ]
        #expect(WorktreeSidebarFilter.apply("log", to: sorted).map(\.id) == ["1", "3"])
        #expect(WorktreeSidebarFilter.apply("log", to: sorted.reversed()).map(\.id) == ["3", "1"])
        #expect(WorktreeSidebarFilter.apply("   ", to: sorted) == sorted)
        #expect(!WorktreeSidebarFilter.isActive("   "))
    }

    @Test(arguments: [
        (nil as String?, 1, "a" as String?),
        (nil, -1, "c"),
        ("a", 1, "b"),
        ("c", 1, "c"),          // clamps at the bottom
        ("a", -1, "a"),         // clamps at the top
        ("gone", 1, "a"),       // highlight filtered away restarts
    ])
    func moveHighlightWalksMatchesInDisplayOrder(current: String?, offset: Int, expected: String?) {
        #expect(WorktreeSidebarFilter.moveHighlight(from: current, by: offset, in: ["a", "b", "c"]) == expected)
    }

    @Test(arguments: [
        (10.0 as CGFloat, 0.0 as CGFloat),  // mostly shown snaps open
        (20.0, 32.0),                       // mostly hidden snaps hidden
        (16.0, 32.0),                       // halfway leans hidden
        (0.0, 0.0),                         // edges and beyond are left alone
        (-20.0, -20.0),
        (400.0, 400.0),
    ])
    func filterRowSlotIsMagnetic(offset: CGFloat, expected: CGFloat) {
        #expect(WorktreeSidebarFilter.snappedOffset(offset, slot: 32) == expected)
    }

    @Test(arguments: [
        (4050.0 as CGFloat, 400.0 as CGFloat, 32.0 as CGFloat?), // overflowing on the first callback
        (50.0, 400.0, nil),       // short list still needs viewport padding
        (432.0, 400.0, 32.0),     // padding now leaves room to hide the slot
        (431.5, 400.0, nil),      // cannot yet scroll past the whole slot
        (4050.0, 0.0, nil),       // viewport has not been laid out
    ])
    func initialParkingUsesScrollableGeometry(contentHeight: CGFloat, viewportHeight: CGFloat, expected: CGFloat?) {
        #expect(WorktreeSidebarFilter.initialParkingOffset(
            contentHeight: contentHeight, viewportHeight: viewportHeight, slot: 32
        ) == expected)
    }

    @Test(arguments: [
        (0.0 as CGFloat, false, 6.0 as CGFloat),  // at the top it sits in its slot
        (32.0, false, -26.0),    // parked: scrolled away with the content
        (-20.0, false, 26.0),    // follows a pull past the top
        (400.0, true, 6.0),      // pinned mid-list stays at rest
        (-20.0, true, 26.0),     // pinned still follows a pull
    ])
    func filterRowRidesItsSlotUnlessPinned(scrollOffset: CGFloat, pinned: Bool, expectedY: CGFloat) {
        #expect(WorktreeSidebarFilter.rowY(scrollOffset: scrollOffset, pinned: pinned, restY: 6) == expectedY)
    }

    @Test func filterRowFadesAsItLeavesTheScrollArea() {
        #expect(WorktreeSidebarFilter.rowOpacity(y: 6, height: 24) == 1)
        #expect(WorktreeSidebarFilter.rowOpacity(y: -12, height: 24) == 0.5)
        #expect(WorktreeSidebarFilter.rowOpacity(y: -26, height: 24) == 0)
    }

    @Test func moveHighlightWithNoMatchesClearsIt() {
        #expect(WorktreeSidebarFilter.moveHighlight(from: "a", by: 1, in: []) == nil)
    }
}
