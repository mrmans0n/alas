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

        let snapshot = NativePeerSidebarSnapshot.build(peers: peers, rows: rows)

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
        let first = NativePeerSidebarSnapshot.build(peers: peers, rows: rows)
        let renamed = NativePeerSidebarSnapshot.build(
            peers: [RemoteHelloPeer(serverId: "z", name: "Renamed", state: "online"), peers[1]],
            rows: rows
        )

        #expect(first.groups.map(\.serverId) == ["a", "z"])
        #expect(renamed.groups.last?.name == "Renamed")
        #expect(renamed.groups.last?.sessions.first?.id == "z:s")
    }

    @Test func statusLabelsDistinguishRevocationAndUnprovenIdentity() {
        #expect(NativePeerState(wireState: "unauthorized").label == "Token revoked")
        #expect(NativePeerState(wireState: "identityUnproven").label == "Identity unproven")
        #expect(NativePeerState(wireState: "unverified").label == "Identity unproven")
        #expect(NativePeerState(wireState: "offline").label == "Offline")
    }

    private func worktreeRow(
        _ id: String, project: String?, worktreeId: String?, branch: String = "main",
        status: String = "idle", updatedAt: Int64 = 0, projectId: String? = nil,
        isMain: Bool? = nil, createdAt: Double? = nil, lastActivity: Double? = nil
    ) -> RemoteSessionSummary {
        let worktree = project.map {
            RemoteWorktreeSummary(
                projectName: $0, worktreeName: branch, branch: branch,
                path: "/\($0)/\(branch)", metricsAvailable: false, comparisonRef: nil,
                commitCount: 0, changedFileCount: 0, addedLines: 0, deletedLines: 0,
                conflictCount: 0, isMain: isMain, createdAt: createdAt, lastActivity: lastActivity
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
        #expect(repos[0].worktrees[0].title == "feat")
        #expect(repos[0].worktrees[0].updatedAt == 30)
        #expect(repos[0].attentionCount == 1)
        #expect(repos[2].worktrees.map(\.title) == ["s5"])
    }

    @Test func peerWorktreesPinMainFirstThenFollowOrdering() {
        let sessions = [
            worktreeRow("a", project: "alas", worktreeId: "wa", branch: "beta", updatedAt: 50, createdAt: 1, lastActivity: 30),
            worktreeRow("m", project: "alas", worktreeId: "wm", branch: "main", updatedAt: 1, isMain: true, createdAt: 0, lastActivity: 0),
            worktreeRow("b", project: "alas", worktreeId: "wb", branch: "alpha", updatedAt: 40, createdAt: 2, lastActivity: 40)
        ]
        func titles(_ mode: AppConfig.WorktreeSortMode) -> [String] {
            NativePeerRepoGroup.build(sessions: sessions, ordering: mode)[0].worktrees.map(\.title)
        }

        #expect(titles(.lastUpdateDesc) == ["main", "alpha", "beta"])
        #expect(titles(.lastUpdateAsc) == ["main", "beta", "alpha"])
        #expect(titles(.creationDesc) == ["main", "alpha", "beta"])
        #expect(titles(.creationAsc) == ["main", "beta", "alpha"])
        #expect(titles(.branchAsc) == ["main", "alpha", "beta"])
        #expect(titles(.manual) == ["main", "beta", "alpha"])
    }

    @Test func peerWorktreesKeepArrivalOrderWhenCreationTimeIsMissing() {
        let sessions = ["z", "a", "m"].enumerated().map { i, name in
            worktreeRow(name, project: "alas", worktreeId: "w\(name)", branch: name, updatedAt: Int64(30 - i))
        }
        let titles = NativePeerRepoGroup.build(sessions: sessions, ordering: .creationAsc)[0].worktrees.map(\.title)
        #expect(titles == ["z", "a", "m"])
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

    private func console(
        _ id: String, project: String?, worktreeId: String?, branch: String? = nil, isMain: Bool? = nil
    ) -> PeerConsoleSummary {
        PeerConsoleSummary(
            consoleId: id, title: "zsh", worktreeId: worktreeId, projectId: project,
            projectName: project, worktreeName: worktreeId, rows: 24, columns: 80,
            worktree: branch.map {
                RemoteWorktreeSummary(
                    projectName: project ?? "", worktreeName: $0, branch: $0,
                    path: "/\(project ?? "")/\($0)", metricsAvailable: false, comparisonRef: nil,
                    commitCount: 0, changedFileCount: 0, addedLines: 0, deletedLines: 0,
                    conflictCount: 0, isMain: isMain
                )
            }
        )
    }

    @Test func consolesJoinTheirSessionWorktreeRowOnOnlinePeersOnly() {
        let peers = [
            RemoteHelloPeer(serverId: "b", name: "Mac B", state: "online"),
            RemoteHelloPeer(serverId: "c", name: "Mac C", state: "offline")
        ]
        let rows = [
            worktreeRow("s1", project: "alas", worktreeId: "w1", branch: "feat", updatedAt: 20),
            worktreeRow("s2", project: "alas", worktreeId: "w2", branch: "fix", updatedAt: 10)
        ]
        let snapshot = NativePeerSidebarSnapshot.build(peers: peers, rows: rows, consoles: [
            "b": [console("c1", project: "alas", worktreeId: "w1", branch: "feat"),
                  console("c2", project: "alas", worktreeId: "w1", branch: "feat")],
            "c": [console("c3", project: "alas", worktreeId: "w1")]
        ])

        let worktrees = snapshot.groups[0].repos(ordering: .lastUpdateDesc).flatMap(\.worktrees)
        #expect(worktrees.map(\.title) == ["feat", "fix"])
        #expect(worktrees[0].sessions.map(\.id) == ["b:s1"])
        #expect(worktrees[0].consoles.map(\.consoleId) == ["c1", "c2"])
        #expect(worktrees[1].consoles.isEmpty)
        #expect(snapshot.groups[1].consoles.isEmpty)
    }

    @Test func consoleOnlyWorktreesAppearInTheirRepoWithMainFirst() {
        let sessions = [
            worktreeRow("s1", project: "alas", worktreeId: "w1", branch: "feat", updatedAt: 20)
        ]
        let consoles = [
            console("c1", project: "alas", worktreeId: "wm", branch: "main", isMain: true),
            // An older host sends no worktree summary; the row falls back to
            // its display names.
            console("c2", project: "cpcl", worktreeId: "legacy")
        ]

        let repos = NativePeerRepoGroup.build(sessions: sessions, consoles: consoles)

        #expect(repos.map(\.name) == ["alas", "cpcl"])
        #expect(repos[0].worktrees.map(\.title) == ["main", "feat"])
        #expect(repos[1].worktrees.map(\.title) == ["legacy"])
    }

    @Test func consoleWithAnEmptyProjectIdLandsInTheUnassignedRepo() {
        let repos = NativePeerRepoGroup.build(
            sessions: [], consoles: [console("c1", project: "", worktreeId: "w")]
        )

        #expect(repos.count == 1)
        #expect(repos[0].projectId == nil)
    }

    @Test func tabsFollowTheHostsTabOrderAndSkipHistory() {
        func session(_ id: String, tab: Int?, active: Bool = true) -> RemoteSessionSummary {
            .init(id: id, title: id, agentId: "claude", status: "idle", canDrive: false, isActive: active, tabIndex: tab)
        }
        func console(_ id: String, tab: Int?) -> PeerConsoleSummary {
            PeerConsoleSummary(
                consoleId: id, title: "zsh", worktreeId: "w", projectId: nil, projectName: nil,
                worktreeName: nil, rows: 24, columns: 80, tabIndex: tab)
        }

        // c1 and c2 are panes of one split tab, listed in pane order.
        #expect(NativePeerWorktreeGroup.tabs(
            sessions: [session("s2", tab: 2), session("old", tab: nil, active: false), session("s1", tab: 1)],
            consoles: [console("c3", tab: 3), console("c1", tab: 0), console("c2", tab: 0)]
        ) == [.console("c1"), .console("c2"), .session("s1"), .session("s2"), .console("c3")])
        // An older host sends no index: sessions as given, then consoles.
        #expect(NativePeerWorktreeGroup.tabs(
            sessions: [session("s2", tab: nil), session("old", tab: nil, active: false), session("s1", tab: nil)],
            consoles: [console("c1", tab: nil)]
        ) == [.session("s2"), .session("s1"), .console("c1")])
    }

    @Test(arguments: [
        ("b", ["a", "c"], "a"),       // the tab before it
        ("a", ["b", "c"], "b"),       // it was first: the new first tab
        ("c", ["a"], "a"),            // skips a neighbour that also closed
        ("b", [], nil),               // nothing left
        ("b", ["a", "b"], "b"),       // still open
        ("x", ["a"], "x"),            // never one of the tabs: left alone
    ] as [(String, [String], String?)])
    func aClosedTabHandsSelectionToItsNeighbour(selected: String, current: [String], expected: String?) {
        let tab = NativePeerTab.session
        #expect(NativePeerWorktreeGroup.reconciledTab(
            tab(selected), previous: ["a", "b", "c"].map(tab), current: current.map(tab)
        ) == expected.map(tab))
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

    @Test(arguments: [
        ("streaming", ActivityState.busy),
        ("awaitingPermission", .permissionRequest),
        ("awaitingInput", .awaitingInput),
        ("idle", nil),
        ("somethingNewer", nil),
    ] as [(String, ActivityState?)])
    func peerSessionTabsTintLikeLocalTabs(status: String, expected: ActivityState?) {
        #expect(row("s", peer: "b", status: status).tabActivityState == expected)
    }
}
