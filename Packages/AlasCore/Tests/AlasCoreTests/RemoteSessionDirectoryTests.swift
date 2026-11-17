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

    @Test func aMachineCheckoutsSessionsJoinTheirLocalProjectsSection() {
        var remote = wt("alas", "feature", path: "/m/feature")
        remote.linkedProjectId = "p1"
        let result = sections([session("s1"), session("s2", project: "p-mini", worktreeId: "w2", worktree: remote)])
        #expect(result.count == 1)
        #expect(result[0].worktrees.count == 2)
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

    @Test(arguments: [
        (["idle", "streaming", "awaitingInput"], "s2"),
        (["idle", "streaming"], "s1"),
        (["idle", "idle"], "s0"),
    ])
    func leadSessionPrefersWaitingThenRunningThenNewest(statuses: [String], expected: String) throws {
        // Index 0 is the newest, as `sections` sorts them.
        let list = statuses.enumerated().map { session("s\($0.offset)", status: $0.element, at: Int64(10 - $0.offset)) }
        let w = try #require(sections(list).first?.worktrees.first)
        #expect(w.leadSession?.id == expected)
    }

    @Test func leadSessionFallsBackToTheNewestClosedOne() throws {
        let w = try #require(sections([session("old", active: false, at: 1), session("new", active: false, at: 5)]).first?.worktrees.first)
        #expect(w.leadSession?.id == "new")
    }

    @Test func attentionFirstKeepsRecencyWithinEachGroup() throws {
        let list = [
            session("a", worktreeId: "idleNew", at: 9),
            session("b", status: "streaming", worktreeId: "running", at: 5),
            session("c", status: "awaitingPermission", worktreeId: "waiting", at: 1),
            session("d", worktreeId: "idleOld", at: 3),
        ]
        let worktrees = try #require(sections(list).first?.worktrees)
        #expect(RemoteSessionDirectory.attentionFirst(worktrees).map(\.id) == ["waiting", "running", "idleNew", "idleOld"])
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

    private func source(_ number: Int, serverId: String? = "owner", live: Bool = true,
                        sessions: [RemoteSessionSummary]) -> RemoteSessionCatalog.Source {
        RemoteSessionCatalog.Source(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(number)")!,
            serverId: serverId, name: "Mac \(number)", isLive: live, sessions: sessions
        )
    }

    /// One session per checkout: (machine, project id, repository key, updatedAt).
    private func projectGroups(_ checkouts: [(Int, String, String?, Int64)]) -> [RemoteSessionCatalog.ProjectGroup] {
        let sources = Dictionary(grouping: checkouts, by: \.0).map { machine, rows in
            source(machine, serverId: "mac\(machine)", sessions: rows.map { _, project, key, at in
                var summary = wt(project.uppercased(), "\(project)-\(machine)", path: "/r/\(project)")
                summary.repositoryKey = key
                return session("\(project)-\(machine)", project: project, worktreeId: project, at: at, worktree: summary)
            })
        }
        return RemoteSessionCatalog.projects(from: RemoteSessionCatalog.hosts(from: sources))
    }

    @Test func oneRepositoryMergesAcrossMachinesNewestFirst() throws {
        let groups = projectGroups([
            (1, "alas", "github.com/o/alas", 5),
            (1, "site", "github.com/o/site", 1),
            (2, "alas", "github.com/o/alas", 9),
        ])
        #expect(groups.map(\.title) == ["ALAS", "SITE"])
        let alas = try #require(groups.first)
        #expect(alas.id == "repo:github.com/o/alas")
        #expect(alas.rows.map(\.worktree.title) == ["alas-2", "alas-1"])
        #expect(alas.hostIDs == [.server("mac2"), .server("mac1")])
    }

    @Test func newSessionPlacementsPreferTheMachineUsedLast() throws {
        let groups = projectGroups([(1, "alas", "k", 5), (2, "alas", "k", 9)])
        let alas = try #require(groups.first { $0.id == "repo:k" })
        #expect(alas.placements.map(\.hostID) == [.server("mac2"), .server("mac1")])
        #expect(alas.placements.map(\.projectId) == ["alas", "alas"])
    }

    @Test func aMachineCheckoutStartsNewSessionsInItsLocalProject() {
        var remote = wt("alas", "feature", path: "/m/feature")
        remote.linkedProjectId = "p1"
        let entry = sections([session("s2", project: "p-ssh", worktreeId: "w2", worktree: remote)])[0].worktrees[0]
        #expect(entry.projectId == "p1")
    }

    @Test(arguments: [
        // A folder, or a host too old to send keys.
        ([(1, "notes", nil), (2, "notes", nil)], 2),
        // Two clones on machine 1 are not guessed between; machine 2's stays whole.
        ([(1, "alas", "k"), (1, "fork", "k"), (2, "alas", "k")], 3),
    ] as [([(Int, String, String?)], Int)])
    func projectsItCannotTellApartStayWithTheirMachine(checkouts: [(Int, String, String?)], expected: Int) {
        #expect(projectGroups(checkouts.map { ($0.0, $0.1, $0.2, 1) }).count == expected)
    }

    @Test func federatedCopiesAppearOnceUnderEachOwningHost() throws {
        let sources = (1...3).map { gateway in
            source(gateway, serverId: "mac\(gateway)", sessions: (1...3).map { owner in
                session(owner == gateway ? "s1" : "mac\(owner):s1", status: "streaming",
                        worktree: wt(changed: 1), serverId: owner == gateway ? nil : "mac\(owner)",
                        serverName: "Mac \(owner)")
            })
        }
        let hosts = RemoteSessionCatalog.hosts(from: sources)
        #expect(hosts.count == 3)
        #expect(hosts.flatMap(\.sections).flatMap(\.worktrees).count == 3)
        #expect(RemoteSessionDirectory.counts(hosts.flatMap(\.sections)) == [.all: 3, .running: 3, .dirty: 3])
        for host in hosts {
            let worktree = try #require(host.sections.first?.worktrees.first)
            #expect(worktree.activeSessions.map(\.id) == ["s1"])
            let route = try #require(host.route(for: "s1"))
            #expect(route.sessionId == "s1")
            #expect(sources.first { $0.id == route.hostID }?.name == host.name)
        }
    }

    @Test(arguments: [(true, true, 1), (false, true, 2), (true, false, 1), (false, false, 1)])
    func liveReportsBeatCacheThenPreferDirectRoutes(directLive: Bool, relayLive: Bool, expected: Int) throws {
        let direct = source(1, live: directLive, sessions: [session("s1", title: "Direct")])
        let relay = source(2, serverId: "relay", live: relayLive, sessions: [
            session("owner:s1", title: "Relayed", at: 9, serverId: "owner", serverName: "Owner"),
        ])
        let host = try #require(RemoteSessionCatalog.hosts(from: [relay, direct]).first { $0.id == .server("owner") })
        let route = try #require(host.route(for: "s1"))
        #expect(route.hostID == (expected == 1 ? direct.id : relay.id))
        #expect(route.sessionId == (expected == 1 ? "s1" : "owner:s1"))
        #expect(host.sections.first?.worktrees.first?.activeSessions.first?.title == (expected == 1 ? "Direct" : "Relayed"))
    }

    @Test(arguments: [true, false])
    func liveOwnerCatalogRemovesSessionsOnlyRelaysStillReport(ownerLive: Bool) throws {
        let owner = source(1, live: ownerLive, sessions: [])
        let relay = source(2, serverId: "relay", sessions: [session("owner:gone", serverId: "owner")])
        let host = try #require(RemoteSessionCatalog.hosts(from: [owner, relay]).first { $0.id == .server("owner") })
        #expect(host.sections.flatMap(\.worktrees).count == (ownerLive ? 0 : 1))
    }

    @Test func relayOnlyOwnerKeepsOneStableRoute() throws {
        let first = source(1, serverId: "relay1", sessions: [session("owner:s1", serverId: "owner", serverName: "Studio")])
        let second = source(2, serverId: "relay2", sessions: [session("owner:s1", serverId: "owner", serverName: "Studio")])
        for sources in [[first, second], [second, first]] {
            let host = try #require(RemoteSessionCatalog.hosts(from: sources).first { $0.id == .server("owner") })
            #expect(host.name == "Studio")
            #expect(host.sections.flatMap(\.worktrees).count == 1)
            #expect(host.route(for: "s1")?.hostID == first.id)
            #expect(host.route(for: "s1")?.sessionId == "owner:s1")
        }
    }

    @Test func unidentifiedPairingsKeepMatchingCheckoutsSeparate() {
        let hosts = RemoteSessionCatalog.hosts(from: [
            source(1, serverId: nil, sessions: [session("s1")]),
            source(2, serverId: nil, sessions: [session("s1")]),
        ])
        #expect(hosts.count == 2)
        #expect(Set(hosts.map(\.id)).count == 2)
        #expect(hosts.flatMap(\.sections).flatMap(\.worktrees).count == 2)
    }

    @Test(arguments: ["s1", "part:session", "owner:session"])
    func relayRoutePreservesTheOriginalSessionID(nativeID: String) throws {
        let direct = source(1, live: false, sessions: [session(nativeID)])
        let relay = source(2, serverId: "relay", sessions: [session("owner:\(nativeID)", serverId: "owner")])
        let host = try #require(RemoteSessionCatalog.hosts(from: [direct, relay]).first { $0.id == .server("owner") })
        #expect(host.sections.first?.worktrees.first?.activeSessions.map(\.id) == [nativeID])
        #expect(host.route(for: nativeID)?.sessionId == "owner:\(nativeID)")
    }

    @Test(arguments: ["awaitingPermission", "awaitingInput"])
    func inboxShowsOneEntryForDirectAndRelayedCopies(status: String) throws {
        let owner = source(1, sessions: [session("s1", status: status)])
        let reports = [owner] + (2...3).map { gateway in
            source(gateway, serverId: "gateway\(gateway)", sessions: [
                session("owner:s1", status: status, serverId: "owner", serverName: "Owner"),
            ])
        }
        let entries = RemoteSessionCatalog.attentionEntries(from: reports)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.id.owner == .server("owner"))
        #expect(entry.id.sessionId == "s1")
        #expect(entry.route.hostID == owner.id)
        #expect(entry.route.sessionId == "s1")
        #expect(entry.hostName == "Mac 1")
    }

    @Test func inboxFiltersPendingRequestsAfterReconcilingOwnerState() {
        let owner = source(1, sessions: [
            session("waiting", status: "awaitingInput"),
            session("answered", status: "idle"),
            session("closed", status: "awaitingPermission", active: false),
        ])
        let relay = source(2, serverId: "gateway", sessions: ["waiting", "answered", "closed", "removed"].map {
            session("owner:\($0)", status: "awaitingPermission", serverId: "owner")
        })
        let entries = RemoteSessionCatalog.attentionEntries(from: [owner, relay])
        #expect(entries.map(\.id.sessionId) == ["waiting"])
    }

    @Test func inboxIdentityStaysStableWhenItsPreferredRouteChanges() throws {
        let sessions = [session("s1", status: "awaitingPermission")]
        let relay = source(2, serverId: "gateway", sessions: [
            session("owner:s1", status: "awaitingPermission", serverId: "owner"),
        ])
        let cached = source(1, live: false, sessions: sessions)
        let online = source(1, live: true, sessions: sessions)
        let before = try #require(RemoteSessionCatalog.attentionEntries(from: [cached, relay]).first)
        let after = try #require(RemoteSessionCatalog.attentionEntries(from: [online, relay]).first)
        #expect(before.id == after.id)
        #expect(before.route.hostID == relay.id)
        #expect(before.route.sessionId == "owner:s1")
        #expect(after.route.hostID == online.id)
        #expect(after.route.sessionId == "s1")
    }

    @Test func inboxKeepsIdenticalSessionIDsOnDifferentOwnersSeparate() {
        let entries = RemoteSessionCatalog.attentionEntries(from: [
            source(1, serverId: "owner1", sessions: [session("s1", status: "awaitingPermission")]),
            source(2, serverId: "owner2", sessions: [session("s1", status: "awaitingPermission")]),
        ])
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.id)).count == 2)
    }
}
