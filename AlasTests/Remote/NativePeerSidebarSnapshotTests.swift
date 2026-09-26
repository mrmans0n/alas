import Testing
@testable import Alas

@MainActor
struct NativePeerSidebarSnapshotTests {
    private func row(_ id: String, peer: String, status: String) -> RemoteSessionSummary {
        RemoteSessionSummary(
            id: "\(peer):\(id)", title: id, agentId: "claude", status: status,
            canDrive: false, serverId: peer, serverName: peer
        )
    }

    @Test func groupsOnlyVerifiedOnlinePeerRowsAndCountsUniqueWaitingSessions() throws {
        let peers = [
            RemoteHelloPeer(serverId: "b", name: "Mac B", state: "online"),
            RemoteHelloPeer(serverId: "c", name: "Mac C", state: "offline"),
            RemoteHelloPeer(serverId: "d", name: "Mac D", state: "unverified")
        ]
        let rows = [
            row("one", peer: "b", status: "awaitingPermission"),
            row("two", peer: "b", status: "awaitingInput"),
            row("one", peer: "b", status: "awaitingPermission"),
            row("three", peer: "b", status: "streaming"),
            row("four", peer: "c", status: "awaitingInput"),
            row("five", peer: "d", status: "awaitingPermission"),
            RemoteSessionSummary(id: "local", title: "Local", agentId: "claude",
                                 status: "awaitingInput", canDrive: false)
        ]

        let snapshot = NativePeerSidebarSnapshot.build(peers: peers, rows: rows, enabled: true)

        #expect(snapshot.groups.map(\.serverId) == ["b", "c", "d"])
        #expect(snapshot.groups[0].sessions.map(\.id).sorted() == ["b:one", "b:three", "b:two"])
        #expect(snapshot.groups[0].attentionCount == 2)
        #expect(snapshot.groups[1].sessions.isEmpty)
        #expect(snapshot.groups[1].attentionCount == 0)
        #expect(snapshot.groups[2].sessions.isEmpty)
        #expect(snapshot.attentionRows.map(\.id).sorted() == ["b:one", "b:two"])
        #expect(snapshot.attentionCount == 2)
    }

    @Test func equalNamesSortByIdentityAndRenameChangesLabelOnly() {
        let peers = [
            RemoteHelloPeer(serverId: "z", name: "Mac", state: "online"),
            RemoteHelloPeer(serverId: "a", name: "Mac", state: "online")
        ]
        let rows = [row("s", peer: "z", status: "idle")]
        let first = NativePeerSidebarSnapshot.build(peers: peers, rows: rows, enabled: true)
        let renamed = NativePeerSidebarSnapshot.build(
            peers: [RemoteHelloPeer(serverId: "z", name: "Renamed", state: "online"), peers[1]],
            rows: rows, enabled: true
        )

        #expect(first.groups.map(\.serverId) == ["a", "z"])
        #expect(renamed.groups.last?.name == "Renamed")
        #expect(renamed.groups.last?.sessions.first?.id == "z:s")
    }

    @Test func flagOffHidesPeersAndTheirAttention() {
        let snapshot = NativePeerSidebarSnapshot.build(
            peers: [RemoteHelloPeer(serverId: "b", name: "B", state: "online")],
            rows: [row("s", peer: "b", status: "awaitingInput")], enabled: false
        )
        #expect(snapshot.groups.isEmpty)
        #expect(snapshot.attentionRows.isEmpty)
        #expect(snapshot.attentionCount == 0)
    }

    @Test func statusLabelsDistinguishRevocationAndUnprovenIdentity() {
        #expect(NativePeerState(wireState: "unauthorized").label == "Token revoked")
        #expect(NativePeerState(wireState: "identityUnproven").label == "Identity unproven")
        #expect(NativePeerState(wireState: "unverified").label == "Identity unproven")
        #expect(NativePeerState(wireState: "offline").label == "Offline")
    }

    private func worktreeRow(
        _ id: String, project: String?, worktreeId: String?, branch: String = "main",
        status: String = "idle", updatedAt: Int64 = 0, projectId: String? = nil
    ) -> RemoteSessionSummary {
        let worktree = project.map {
            RemoteWorktreeSummary(
                projectName: $0, worktreeName: branch, branch: branch,
                path: "/\($0)/\(branch)", metricsAvailable: false, comparisonRef: nil,
                commitCount: 0, changedFileCount: 0, addedLines: 0, deletedLines: 0,
                conflictCount: 0
            )
        }
        return RemoteSessionSummary(
            id: "b:\(id)", title: id, agentId: "claude", status: status, canDrive: false,
            projectId: projectId ?? project, worktreeId: worktreeId, updatedAt: updatedAt,
            worktree: worktree, serverId: "b", serverName: "Mac B"
        )
    }

    @Test func peerSessionsFoldIntoReposAndWorktreesInRecencyOrder() {
        let sessions = [
            worktreeRow("s1", project: "alas", worktreeId: "w1", branch: "feat", status: "awaitingInput", updatedAt: 30),
            worktreeRow("s2", project: "cpcl", worktreeId: "w2", updatedAt: 20),
            worktreeRow("s3", project: "alas", worktreeId: "w1", branch: "feat", status: "streaming", updatedAt: 10),
            worktreeRow("s4", project: "alas", worktreeId: "w3", updatedAt: 5),
            worktreeRow("s5", project: nil, worktreeId: nil, updatedAt: 1)
        ]

        let repos = NativePeerRepoGroup.build(sessions: sessions)

        #expect(repos.map(\.name) == ["alas", "cpcl", NativePeerRepoGroup.unassignedName])
        #expect(repos[0].worktrees.count == 2)
        #expect(repos[0].worktrees[0].sessions.map(\.id) == ["b:s1", "b:s3"])
        #expect(repos[0].worktrees[0].primarySession.id == "b:s1")
        #expect(repos[0].worktrees[0].title == "feat")
        #expect(repos[0].worktrees[0].updatedAt == 30)
        #expect(repos[0].attentionCount == 1)
        #expect(repos[2].worktrees.map(\.title) == ["s5"])
    }

    @Test func peerReposGroupByProjectIdentityNotDisplayName() {
        // Two distinct projects that happen to share a display name must not
        // merge into one repo group, and a rename must not split one project
        // into two. Input is in the recency order `build` always receives
        // (most recent session first), so the rename's newer label wins.
        let sessions = [
            worktreeRow("s3", project: "renamed-alas", worktreeId: "w1", updatedAt: 30, projectId: "proj-a"),
            worktreeRow("s1", project: "alas", worktreeId: "w1", updatedAt: 20, projectId: "proj-a"),
            worktreeRow("s2", project: "alas", worktreeId: "w1", updatedAt: 10, projectId: "proj-b")
        ]

        let repos = NativePeerRepoGroup.build(sessions: sessions)

        #expect(repos.count == 2)
        #expect(repos[0].name == "renamed-alas", "the most recent session's label wins on rename")
        #expect(repos[0].worktrees.flatMap(\.sessions).map(\.id) == ["b:s3", "b:s1"])
        #expect(repos[1].name == "alas")
        #expect(repos[1].worktrees.flatMap(\.sessions).map(\.id) == ["b:s2"])
    }

    @Test func peerWorktreeStatusRanksWaitingOverRunningAndHidesIdle() {
        let waiting = NativePeerWorktreeGroup(id: "w", sessions: [
            worktreeRow("a", project: "alas", worktreeId: "w", status: "streaming"),
            worktreeRow("b", project: "alas", worktreeId: "w", status: "awaitingPermission")
        ])
        #expect(waiting.status?.note == "needs permission")
        #expect(waiting.status?.pulses == false)

        let running = NativePeerWorktreeGroup(id: "w", sessions: [
            worktreeRow("a", project: "alas", worktreeId: "w", status: "streaming")
        ])
        #expect(running.status?.note == "running")
        #expect(running.status?.pulses == true)

        let idle = NativePeerWorktreeGroup(id: "w", sessions: [
            worktreeRow("a", project: "alas", worktreeId: "w")
        ])
        #expect(idle.status == nil)
    }
}
