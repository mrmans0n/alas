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
}
