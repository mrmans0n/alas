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
}
