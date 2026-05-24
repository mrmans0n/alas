import Testing
import Foundation
@testable import Alas

struct TabMergeConflictCodingTests {
    @Test func roundTripsPreservingShowBase() throws {
        let state = MergeConflictTabState(
            worktreeId: "wt-abc",
            relativePath: "src/foo.swift",
            title: "foo.swift",
            showBase: true
        )
        let tab = Tab.mergeConflict(state)
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        guard case .mergeConflict(let s) = decoded else {
            Issue.record("expected .mergeConflict case")
            return
        }
        #expect(s.id == "merge:wt-abc:src/foo.swift")
        #expect(s.worktreeId == "wt-abc")
        #expect(s.relativePath == "src/foo.swift")
        #expect(s.title == "foo.swift")
        #expect(s.showBase == true)
    }

    @Test func idIsDerivedFromWorktreeAndPath() {
        let state = MergeConflictTabState(
            worktreeId: "wt",
            relativePath: "a/b.txt",
            title: "b.txt"
        )
        #expect(state.id == "merge:wt:a/b.txt")
    }

    @Test func defaultsShowBaseToFalse() {
        let state = MergeConflictTabState(
            worktreeId: "wt",
            relativePath: "a.txt",
            title: "a.txt"
        )
        #expect(state.showBase == false)
    }
}
