import Testing
import Foundation
@testable import Alas

struct CommitTabStateTests {
    @Test func idIsStablePerWorktreeAndSha() {
        let a = CommitTabState(worktreeId: "wt-1", sha: "a3f2c1d", title: "x")
        let b = CommitTabState(worktreeId: "wt-1", sha: "a3f2c1d", title: "different title")
        #expect(a.id == b.id)
        let c = CommitTabState(worktreeId: "wt-2", sha: "a3f2c1d", title: "x")
        #expect(a.id != c.id)
    }

    @Test func codableRoundTripPreservesAllFields() throws {
        let s = CommitTabState(worktreeId: "wt-1", sha: "deadbeefcafebabe", title: "fix: foo")
        let data = try JSONEncoder().encode(Tab.commit(s))
        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        guard case .commit(let r) = decoded else {
            Issue.record("decoded tab was not .commit")
            return
        }
        #expect(r.id == s.id)
        #expect(r.worktreeId == "wt-1")
        #expect(r.sha == "deadbeefcafebabe")
        #expect(r.title == "fix: foo")
    }
}
