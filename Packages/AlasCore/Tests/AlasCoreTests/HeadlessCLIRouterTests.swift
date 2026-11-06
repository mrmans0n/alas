import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

@MainActor
struct HeadlessCLIRouterTests {
    nonisolated static let screenBound: [AlasCLIRequest.Command] = [
        .open(paths: ["/srv/a"]), .openAt(path: "/srv/a", line: 1, endLine: nil),
        .preview(.init(action: .list)), .computer(.init(action: .apps)), .device(.list), .worktree(.switch(target: "main")),
        .workspace(.list), .workspace(.show(checkoutID: UUID())),
    ]

    /// Agents and anonymous shell callers (cwd only) get the same refusal.
    @Test(arguments: screenBound, [String?.none, "acp-1"])
    func screenBoundCommandsAreRefusedOnAHeadlessHost(command: AlasCLIRequest.Command, session: String?) async {
        let router = AlasCLICommandRouter.headless(host: AlasHost(core: AlasCoreContext(
            projects: ProjectsManager(persistedProjects: []), runHistoryStore: nil, attentionStore: .scratch())))
        let response = await router.handle(.init(version: 1, sessionId: session, cwd: "/srv/a", command: command))
        #expect(response == .error("Not available on a headless host."))
    }

    /// A paired Mac shows the local-changes review, so the host lists it
    /// once an agent opens it.
    @Test func reviewingLocalChangesOnAHeadlessHostListsIt() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("alas-headless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        let project = ProjectConfig(id: "p", name: "p", path: path.path, color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        let worktree = Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
            path: path, status: .clean, lastActivity: .distantPast
        )
        projects.insertOptimisticWorktree(worktree)
        let core = AlasCoreContext(
            projects: projects, runHistoryStore: nil, attentionStore: .scratch(),
            reviewDrafts: ReviewDraftCommentStore(url: path.appendingPathComponent("review-drafts.json")),
            reviewSessions: ReviewSessionStore(url: path.appendingPathComponent("review-sessions.json"))
        )
        let router = AlasCLICommandRouter.headless(host: AlasHost(core: core))

        let response = await router.handle(.init(version: 1, sessionId: nil, cwd: path.path, command: .review(.localChanges(worktree: nil))))

        let sessionID = ReviewDraftSessionID.localChanges(worktreeID: worktree.id, worktreePath: path, scope: .all)
        #expect(response == .text([
            "Opened review of local changes in Alas.",
            ReviewsAPI.jsonLine(["session_id": sessionID.rawValue]),
        ]))
        #expect(core.openedLocalChangesReviews[worktree.id] != nil)
    }

    // MARK: Outbound peer links

    private final class FakeLink: RemotePeerConnecting {
        var state: RemotePeerConnection.State = .idle
        let emit: @MainActor (RemotePeerConnection.Event) -> Void
        init(emit: @escaping @MainActor (RemotePeerConnection.Event) -> Void) { self.emit = emit }
        func connect() {}
        func disconnect() {}
        func send(_ message: RemoteClientMessage) {}
    }

    private final class PeerRecords: RemotePeerStore {
        var peers: [RemotePeer]
        init(_ peers: [RemotePeer]) { self.peers = peers }
        func load() -> [RemotePeer] { peers }
        func save(_ peers: [RemotePeer]) { self.peers = peers }
    }

    private final class PeerDevices: RemoteDeviceStore {
        var devices: [RemoteDevice] = []
        func load() -> [RemoteDevice] { devices }
        func save(_ devices: [RemoteDevice]) { self.devices = devices }
    }

    /// A host's links over `records`, connected, and the link each one dialled.
    private func hostLinks(_ records: [RemotePeer]) -> (delegation: HostPeerDelegation, dialled: () -> [String: FakeLink]) {
        var dialled: [String: FakeLink] = [:]
        let links = RemotePeerManager(
            store: PeerRecords(records), pairing: RemotePairingService(store: PeerDevices()),
            localIdentity: { .init(serverId: "", name: "", origins: []) },
            makeConnection: { peer, onEvent in
                let link = FakeLink(emit: onEvent)
                dialled[peer.id] = link
                return link
            }
        )
        let delegation = HostPeerDelegation(links: links)
        links.connectAll()
        return (delegation, { dialled })
    }

    /// Channels follow the link, with nothing else driving them on a host: the
    /// app gets the same from its session list.
    @Test func headlessAgentListIncludesOutboundPeers() throws {
        let hello = RemotePeerConnection.Event.hello(
            serverId: "mac", name: "Laptop", protocolVersion: RemoteProtocolVersion.current, federationEnabled: true,
            capabilities: [HostProtocolCapability.v1, HostProtocolCapability.eventsV1, HostProtocolCapability.delegationV1]
        )
        let (delegation, dialled) = hostLinks([RemotePeer(
            id: "p", serverId: "mac", name: "Laptop", origins: ["http://laptop:1"], token: "t", publicKey: "key", addedAt: .distantPast
        )])
        let link = try #require(dialled()["p"])
        link.emit(hello)
        link.emit(.stateChanged(.online))
        #expect(delegation.client.peers == [
            ACPDelegationPeerInfo(name: "Laptop", serverId: "mac", state: .online, supportsDelegation: true),
        ])
        #expect(delegation.channels.channel(for: "mac") != nil)

        link.emit(.stateChanged(.offline))
        #expect(delegation.client.peers.map(\.state) == [.offline])
        #expect(delegation.channels.channel(for: "mac") == nil)
    }

    /// A Mac that paired with this host and was never added here has no token.
    @Test func inboundOnlyPeerIsNotOfferedAsATarget() {
        let (delegation, dialled) = hostLinks([RemotePeer(
            id: "p", serverId: "mac", name: "Laptop", origins: ["http://laptop:1"], token: "", localDeviceId: "d", addedAt: .distantPast
        )])
        #expect(delegation.client.peers.isEmpty)
        #expect(dialled().isEmpty)
    }
}
