import Foundation
import Testing
import AlasAgents
import AlasModel
@testable import AlasHostCore

@MainActor
struct PeerDelegationClientTests {
    @MainActor final class FakeLinks: FederatedPeerLinks {
        var sessionCarryingPeers: [FederatedPeerInfo] = [FederatedPeerInfo(serverId: "mini", name: "Mini")]
        var capabilities: Set<String> = [HostProtocolCapability.delegationV1]
        var hello: [RemoteHelloPeer] = []
        var onFederationEvent: (@MainActor (FederatedPeerLinkEvent) -> Void)?
        var helloPeers: [RemoteHelloPeer] { hello }
        func sendToPeer(_ message: RemoteClientMessage, serverId: String) {}
        func peerSupports(_ capability: String, serverId: String) -> Bool { capabilities.contains(capability) }
    }

    /// A channel that answers each request with `reply`, and the requests it saw.
    @MainActor final class Peer {
        var requests: [HostRequest] = []
        var reply: HostResponse = .done
        weak var channel: PeerHostChannel?

        func makeChannel() -> PeerHostChannel {
            let channel = PeerHostChannel { [unowned self] message in
                requests.append(message.request)
                self.channel?.receive(.response(id: message.id, result: reply))
            }
            self.channel = channel
            return channel
        }
    }

    let links = FakeLinks()
    let peer = Peer()

    func client(channelAvailable: Bool = true) -> PeerDelegationClient {
        let channel = peer.makeChannel()
        return PeerDelegationClient(links: links, channel: { _ in channelAvailable ? channel : nil })
    }

    @Test func outdatedPeerIsNotSentARequest() async {
        links.capabilities = []
        let result = await client().send(serverId: "mini", sessionID: "c1", prompt: "go")
        #expect(result.failureValue == .outdated(peer: "Mini"))
        #expect(peer.requests.isEmpty)
    }

    /// A peer's name is set by a person and reaches agents' prompts, in the
    /// list and in what a failed request says.
    @Test func peerNamesLeaveSanitized() async {
        let hostile = "Mi\u{202E}ni\n`x`"
        links.hello = [
            RemoteHelloPeer(serverId: "mini", name: hostile, state: "online"),
            RemoteHelloPeer(serverId: "blank", name: "\u{202E}", state: "offline"),
        ]
        links.sessionCarryingPeers = [FederatedPeerInfo(serverId: "mini", name: hostile)]
        links.capabilities = []
        let client = client()

        #expect(client.peers.map(\.name) == ["Mini x", "blank"])
        #expect(await client.send(serverId: "mini", sessionID: "c1", prompt: "go").failureValue == .outdated(peer: "Mini x"))
        #expect(await client.send(serverId: "blank", sessionID: "c1", prompt: "go").failureValue == .unreachable(peer: "blank"))
    }

    @Test func unverifiedOrOfflinePeerIsUnreachable() async {
        links.sessionCarryingPeers = []
        let result = await client().interrupt(serverId: "mini", sessionID: "c1")
        #expect(result.failureValue == .unreachable(peer: "mini"))
        #expect(peer.requests.isEmpty)
    }

    @Test func peerWhoseLinkWasRefusedIsRevoked() async {
        links.sessionCarryingPeers = []
        links.hello = [RemoteHelloPeer(serverId: "mini", name: "Mini", state: "unauthorized")]
        let result = await client().status(serverId: "mini", sessionIDs: ["c1"])
        #expect(result.failureValue == .revoked(peer: "Mini"))
        #expect(peer.requests.isEmpty)
    }

    @Test func peerWithoutAChannelIsUnreachable() async {
        let result = await client(channelAvailable: false).status(serverId: "mini", sessionIDs: ["c1"])
        #expect(result.failureValue == .unreachable(peer: "Mini"))
    }

    @Test(arguments: [
        (HostResponse.failure(error: .session(refusal: .notFound)), ACPPeerError.notFound),
        (.failure(error: .session(refusal: .promptRejected)), .refused("The session did not take the prompt.")),
        (.failure(error: .failed(message: "Agents on that Mac may not use this one.")), .refused("Agents on that Mac may not use this one.")),
        // An oversized reply is a refusal, never proof the child is gone.
        (.failure(error: .failed(message: "The reply is too large.")), .refused("The reply is too large.")),
        (.failure(error: .failed(message: PeerHostChannel.unansweredMessage)), .unreachable(peer: "Mini")),
        (.failure(error: .failed(message: FederatedSessionsProvider.peerUnavailableMessage)), .unreachable(peer: "Mini")),
        (.failure(error: .peerIdentityUnproven), .unproven(peer: "Mini")),
    ])
    func mapsHostFailures(response: HostResponse, error: ACPPeerError) async {
        peer.reply = response
        let client = client()
        #expect(await client.send(serverId: "mini", sessionID: "c1", prompt: "go").failureValue == error)
        #expect(await client.discover(serverId: "mini", repository: nil).failureValue == error)
    }

    @Test func startAnswersWithTheChildState() async {
        peer.reply = .delegation(.started(sessionID: "c1", state: "running"))
        let request = ACPPeerChildStartRequest(
            childID: "c1", target: .newWorktree(projectID: "p", branch: "fix", base: "main", expectedBaseSHA: "abc"),
            agentID: "codex", modelID: nil, reasoning: nil, role: "reviewer", autoRun: true, prompt: "go"
        )
        let result = await client().start(serverId: "mini", request)
        #expect(result == .success(ACPPeerStartReply(sessionID: "c1", state: "running")))
        #expect(peer.requests == [.delegation(.start(HostDelegationStart(
            childID: "c1", target: .newWorktree(projectID: "p", branch: "fix", base: "main", expectedBaseSHA: "abc"),
            agentID: "codex", modelID: nil, reasoning: nil, role: "reviewer", autoRun: true, prompt: "go"
        )))])
    }

    @Test func outboxPageCarriesEntriesAndMore() async {
        let entry = ACPPeerOutboxEntry(seq: 4, messageId: "m", childSessionId: "c1", prompt: "done", kind: .prompt, createdAt: 9)
        peer.reply = .delegation(.outbox(entries: [entry], hasMore: true, store: "s-new"))
        let result = await client().outbox(serverId: "mini", after: 3, store: "s-old")
        #expect(result == .success(ACPPeerOutboxPage(entries: [entry], hasMore: true, store: "s-new")))
        #expect(peer.requests == [.delegation(.outbox(after: 3, store: "s-old"))])
    }

    @Test(arguments: [
        ("online", ACPDelegationPeerState.online), ("unverified", .unverified), ("incompatible", .incompatible),
        ("offline", .offline), ("connecting", .offline), ("unauthorized", .revoked),
    ])
    func peersReportTheirLinkState(helloState: String, state: ACPDelegationPeerState) {
        links.hello = [RemoteHelloPeer(serverId: "mini", name: "Mini", state: helloState)]
        links.capabilities = []
        #expect(client().peers == [ACPDelegationPeerInfo(name: "Mini", serverId: "mini", state: state, supportsDelegation: false)])
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
