import Testing
import Foundation
@testable import Alas

struct RepoSelectorRecentsTests {
    @Test func bumpProjectPrependsAndDedupes() {
        var r = RepoSelectorRecents()
        r.bumpProject("p1")
        r.bumpProject("p2")
        r.bumpProject("p1")  // moves to front
        #expect(r.projectIds == ["p1", "p2"])
    }

    @Test func bumpProjectCapsAtFive() {
        var r = RepoSelectorRecents()
        for id in ["p1", "p2", "p3", "p4", "p5", "p6"] { r.bumpProject(id) }
        #expect(r.projectIds == ["p6", "p5", "p4", "p3", "p2"])
    }

    @Test func bumpWorktreePrependsPerProjectAndCaps() {
        var r = RepoSelectorRecents()
        for id in ["w1", "w2", "w3", "w4", "w5", "w6"] {
            r.bumpWorktree(id, in: "proj")
        }
        r.bumpWorktree("w2", in: "proj")
        #expect(r.worktreeIdsByProject["proj"] == ["w2", "w6", "w5", "w4", "w3"])
    }

    @Test func bumpWorktreeKeepsProjectsIndependent() {
        var r = RepoSelectorRecents()
        r.bumpWorktree("w1", in: "a")
        r.bumpWorktree("w1", in: "b")
        #expect(r.worktreeIdsByProject["a"] == ["w1"])
        #expect(r.worktreeIdsByProject["b"] == ["w1"])
    }

    @Test func liveProjectsFiltersDangling() {
        var r = RepoSelectorRecents()
        r.projectIds = ["p1", "p2", "p3"]
        let live = r.liveProjectIds(validProjectIds: ["p1", "p3"])
        #expect(live == ["p1", "p3"])
    }

    @Test func liveWorktreesFiltersDangling() {
        var r = RepoSelectorRecents()
        r.worktreeIdsByProject = ["p1": ["w1", "w2", "w3"]]
        let live = r.liveWorktreeIds(in: "p1", validWorktreeIds: ["w1", "w3"])
        #expect(live == ["w1", "w3"])
    }

    @Test func liveWorktreesReturnsEmptyForUnknownProject() {
        let r = RepoSelectorRecents()
        #expect(r.liveWorktreeIds(in: "missing", validWorktreeIds: ["w1"]) == [])
    }

    // MARK: - Flat global recents (recentWorktreeRefs)

    @Test func bumpWorktreeUpdatesRecentWorktreeRefsAcrossProjects() {
        var r = RepoSelectorRecents()
        r.bumpWorktree("w1", in: "A")
        r.bumpWorktree("w2", in: "A")
        r.bumpWorktree("w3", in: "B")
        r.bumpWorktree("w4", in: "A")
        // Newest first; cross-project order is preserved (NOT bucketed by project).
        #expect(r.recentWorktreeRefs == [
            .init(projectId: "A", worktreeId: "w4"),
            .init(projectId: "B", worktreeId: "w3"),
            .init(projectId: "A", worktreeId: "w2"),
            .init(projectId: "A", worktreeId: "w1"),
        ])
    }

    @Test func bumpWorktreeDedupesByProjectAndWorktreePair() {
        var r = RepoSelectorRecents()
        r.bumpWorktree("w1", in: "A")
        r.bumpWorktree("w1", in: "B")  // different project; both entries kept
        r.bumpWorktree("w1", in: "A")  // moves A/w1 back to the front
        #expect(r.recentWorktreeRefs == [
            .init(projectId: "A", worktreeId: "w1"),
            .init(projectId: "B", worktreeId: "w1"),
        ])
    }

    @Test func bumpWorktreeCapsRecentWorktreeRefsAtFive() {
        var r = RepoSelectorRecents()
        for i in 1...7 {
            r.bumpWorktree("w\(i)", in: "A")
        }
        #expect(r.recentWorktreeRefs.count == RepoSelectorRecents.recentWorktreeRefCap)
        #expect(r.recentWorktreeRefs.map(\.worktreeId) == ["w7", "w6", "w5", "w4", "w3"])
    }

    @Test func liveRecentWorktreeRefsFiltersDanglingByPair() {
        var r = RepoSelectorRecents()
        r.bumpWorktree("w1", in: "A")
        r.bumpWorktree("w2", in: "B")
        r.bumpWorktree("w3", in: "A")
        // B/w2 visible; A/w1 not visible (dropped); A/w3 visible.
        let live = r.liveRecentWorktreeRefs(projectsWithVisibleWorktrees: [
            "A": ["w3"],
            "B": ["w2"],
        ])
        #expect(live == [
            .init(projectId: "A", worktreeId: "w3"),
            .init(projectId: "B", worktreeId: "w2"),
        ])
    }

    @Test func liveRecentWorktreeRefsDropsRefsForUnknownProject() {
        var r = RepoSelectorRecents()
        r.bumpWorktree("w1", in: "A")
        r.bumpWorktree("w2", in: "missing")
        let live = r.liveRecentWorktreeRefs(projectsWithVisibleWorktrees: [
            "A": ["w1"],
        ])
        #expect(live == [.init(projectId: "A", worktreeId: "w1")])
    }
}
