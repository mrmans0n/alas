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

    /// A host's links over `records`, connected, and the link each one dialled.
    private func hostLinks(_ records: [RemotePeer]) -> (delegation: HostPeerDelegation, dialled: () -> [String: FakeLink]) {
        var dialled: [String: FakeLink] = [:]
        let links = RemotePeerManager(
            store: MemoryPeerStore(peers: records), pairing: RemotePairingService(store: MemoryDeviceStore()),
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

    private final class FakeRoutes: PeerDeviceRoutes {
        var open: [String: Int] = [:]
        private(set) var sent: [HostClientMessage] = []
        var onAcknowledgedCapabilitiesChange: (@MainActor (String) -> Void)?
        var onPeerHostReply: (@MainActor (String, Int?, HostServerMessage) -> Void)?
        func route(toDevice deviceId: String, acknowledging capability: String) -> Int? {
            capability == HostProtocolCapability.delegationReverseV1 ? open[deviceId] : nil
        }
        func send(_ message: RemoteServerMessage, toDevice deviceId: String, acknowledging capability: String) -> Bool {
            guard route(toDevice: deviceId, acknowledging: capability) != nil, case .peerHost(let request) = message else { return false }
            sent.append(request)
            return true
        }
        /// Waits for request `id` and answers it as device `deviceId`.
        func answer(_ id: Int, from deviceId: String, with result: HostResponse) async throws {
            try await eventually { await MainActor.run { self.sent.contains { $0.id == id } } }
            onPeerHostReply?(deviceId, open[deviceId], .response(id: id, result: result))
        }
    }

    /// A Mac that paired with this host inbound-only, and proved its key doing
    /// so, is reached over its own link once that link acknowledges the route:
    /// requests go back down that device's socket, and only its answers count.
    @Test func anInboundOnlyMacIsReachedOverItsOwnLinkOnceItAcknowledgesTheRoute() async throws {
        let pairing = RemotePairingService(store: MemoryDeviceStore(devices: [RemoteDevice(
            id: "d", name: "Laptop", tokenHash: "h", createdAt: .distantPast, lastSeenAt: nil, kind: .alasInstance,
            peerServerId: "mac", peerPublicKey: "key", scope: .delegation
        )]))
        let links = RemotePeerManager(
            store: MemoryPeerStore(peers: [RemotePeer(
                id: "p", serverId: "mac", name: "Laptop", origins: [], token: "", localDeviceId: "d", addedAt: .distantPast
            )]),
            pairing: pairing, localIdentity: { .init(serverId: "", name: "", origins: []) },
            makeConnection: { _, onEvent in FakeLink(emit: onEvent) }
        )
        let routes = FakeRoutes()
        let delegation = HostPeerDelegation(links: links, routes: routes)
        defer { delegation.stop() }
        var available: [String] = []
        delegation.client.onAvailabilityChanged = { available.append($0) }
        links.connectAll()
        #expect(delegation.client.peers == [
            ACPDelegationPeerInfo(name: "Laptop", serverId: "mac", state: .offline, supportsDelegation: false),
        ])

        routes.open["d"] = 1
        routes.onAcknowledgedCapabilitiesChange?("d")
        try await routes.answer(1, from: "d", with: .snapshot(snapshot: HostSnapshot(
            cursor: HostCursor(generation: UUID(), sequence: 0), projects: [], worktrees: [], workspaceCheckouts: [], runs: [],
            sessions: []
        )))
        try await routes.answer(2, from: "d", with: .subscribed)
        try await eventually { await MainActor.run { available == ["mac"] } }
        #expect(delegation.client.peers.map(\.state) == [.online])

        async let interrupted = delegation.client.interrupt(serverId: "mac", sessionID: "child")
        try await eventually { await MainActor.run { routes.sent.count == 3 } }
        routes.onPeerHostReply?("other", 1, .response(id: 3, result: .delegation(.interrupted(cancelRequested: false))))
        // From an older socket of the same device, which the route has left.
        routes.onPeerHostReply?("d", 0, .response(id: 3, result: .delegation(.interrupted(cancelRequested: false))))
        try await routes.answer(3, from: "d", with: .delegation(.interrupted(cancelRequested: true)))
        #expect(await interrupted == .success(true))
    }

    /// A Mac that paired with this host and was never added here has no token,
    /// and one whose device never proved its key has no route back either.
    @Test func inboundOnlyPeerIsNotOfferedAsATarget() {
        let (delegation, dialled) = hostLinks([RemotePeer(
            id: "p", serverId: "mac", name: "Laptop", origins: ["http://laptop:1"], token: "", localDeviceId: "d", addedAt: .distantPast
        )])
        #expect(delegation.client.peers.isEmpty)
        #expect(dialled().isEmpty)
    }
}
