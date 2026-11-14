import Foundation
import Testing
@testable import AlasCore

@Suite struct RemoteSessionDirectoryTests {
    private func wt(_ project: String = "alas", _ name: String = "main", branch: String = "main", path: String = "/r/main", changed: Int = 0) -> RemoteWorktreeSummary {
        RemoteWorktreeSummary(projectName: project, worktreeName: name, branch: branch, path: path, metricsAvailable: true, comparisonRef: nil, commitCount: 0, changedFileCount: changed, addedLines: 0, deletedLines: 0, conflictCount: 0)
    }

    private func session(_ id: String, title: String = "t", status: String = "idle", active: Bool = true, project: String? = "p1", worktreeId: String? = "w1", at: Int64 = 1, worktree: RemoteWorktreeSummary? = nil, serverId: String? = nil, serverName: String? = nil) -> RemoteSessionSummary {
        RemoteSessionSummary(id: id, title: title, agentId: "a", status: status, canDrive: false, isActive: active, projectId: project, worktreeId: worktreeId, updatedAt: at, worktree: worktree ?? wt(), serverId: serverId, serverName: serverName)
    }

    private func sections(_ s: [RemoteSessionSummary]) -> [RemoteRepoSection] {
        RemoteSessionDirectory.sections(s, localHostName: "Mac")
    }

    @Test(arguments: [
        (["w1", "w1"], 1),
        (["w1", "w2"], 2),
        ([nil, nil], 1),  // same path
    ] as [([String?], Int)])
    func groupsByRepoThenWorktree(ids: [String?], expected: Int) {
        let s = ids.enumerated().map { session("s\($0.offset)", worktreeId: $0.element) }
        let result = sections(s)
        #expect(result.count == 1)
        #expect(result[0].worktrees.count == expected)
    }

    @Test func worktreeKeyFallsBackToSessionIdWithoutPathOrId() {
        let bare = { (id: String) in
            RemoteSessionSummary(id: id, title: "t", agentId: "a", status: "idle", canDrive: false, projectId: nil, worktreeId: nil)
        }
        let result = sections([bare("a"), bare("b")])
        #expect(result.count == 1)
        #expect(result[0].title == "Other")
        #expect(result[0].worktrees.map(\.id).sorted() == ["a", "b"])
    }

    @Test func federatedSessionsGroupUnderTheirHost() {
        let local = session("s1")
        let remote = session("srv:s1", serverId: "srv", serverName: "Studio")
        let result = sections([local, remote])
        #expect(result.count == 2)
        #expect(Set(result.map(\.hostName)) == [nil, "Studio"])
    }

    @Test func closedSessionsAreSeparated() {
        let result = sections([session("a"), session("b", active: false)])
        let w = result[0].worktrees[0]
        #expect(w.activeSessions.map(\.id) == ["a"])
        #expect(w.closedSessions.map(\.id) == ["b"])
    }

    @Test func sortsByRecencyThenTitle() {
        let result = sections([
            session("a", project: "old", worktreeId: "x", at: 1, worktree: wt("Old")),
            session("b", project: "new", worktreeId: "y", at: 9, worktree: wt("New")),
        ])
        #expect(result.map(\.title) == ["New", "Old"])
    }

    @Test(arguments: [
        (RemoteSessionFilter.running, "streaming", 0, true),
        (.running, "idle", 0, false),
        (.dirty, "idle", 2, true),
        (.dirty, "idle", 0, false),
    ])
    func filtersMatchTheWebClient(filter: RemoteSessionFilter, status: String, changed: Int, kept: Bool) {
        let s = sections([session("a", status: status, worktree: wt(changed: changed))])
        #expect(RemoteSessionDirectory.filter(s, by: filter, query: "").count == (kept ? 1 : 0))
    }

    @Test(arguments: [("awaitingPermission", true), ("awaitingInput", true), ("streaming", false), ("idle", false)])
    func attentionOnlyForActiveSessionsAwaitingTheUser(status: String, expected: Bool) {
        #expect(sections([session("a", status: status)])[0].worktrees[0].needsAttention == expected)
        #expect(!sections([session("a", status: status, active: false)])[0].worktrees[0].needsAttention)
    }

    @Test func closedSessionsNeverCountAsRunning() {
        let s = sections([session("a", status: "streaming", active: false)])
        #expect(RemoteSessionDirectory.filter(s, by: .running, query: "").isEmpty)
    }

    @Test(arguments: ["ALAS", "feature", "feat/x", "fix login", "LOGIN"])
    func queryMatchesRepoWorktreeBranchOrSessionTitle(query: String) {
        let s = sections([session("a", title: "Fix login", worktree: wt("alas", "feature", branch: "feat/x"))])
        #expect(RemoteSessionDirectory.filter(s, by: .all, query: query).count == 1)
        #expect(RemoteSessionDirectory.filter(s, by: .all, query: "zzz").isEmpty)
    }

    @Test func countsPerFilter() {
        let s = sections([
            session("a", status: "streaming", project: "p1", worktree: wt("A", changed: 1)),
            session("b", project: "p2", worktreeId: "w2", worktree: wt("B", changed: 3)),
            session("c", project: "p3", worktreeId: "w3", worktree: wt("C")),
        ])
        let c = RemoteSessionDirectory.counts(s)
        #expect(c[.all] == 3)
        #expect(c[.running] == 1)
        #expect(c[.dirty] == 2)
    }
}
