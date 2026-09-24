import Foundation
import Testing
@testable import Alas

@MainActor
struct NativePeerNavigationTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private final class FakeLinks: FederatedPeerLinks {
        var sessionCarryingPeers: [FederatedPeerInfo] = [.init(serverId: "B", name: "Mac B")]
        var onFederationEvent: (@MainActor (FederatedPeerLinkEvent) -> Void)?
        func sendToPeer(_ message: RemoteClientMessage, serverId: String) {}
        func receive(_ message: RemoteServerMessage) {
            onFederationEvent?(.message(serverId: "B", message))
        }
    }

    @Test func peerSelectionOverlaysLocalSelectionAndLocalClickClosesIt() {
        let state = AppState(store: MemoryStore())
        let localSelection = state.selectedWorktreeId
        let links = FakeLinks()
        let client = NativePeerSessions(federation: FederatedSessionsProvider(links: links), peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        state.installNativePeerSessionsForTesting(client)
        client.start()
        links.receive(.sessionList(sessions: [
            .init(id: "s", title: "Peer session", agentId: "claude", status: "idle", canDrive: false)
        ]))
        client.select("B:s")
        #expect(client.selectedSessionId == "B:s")
        #expect(state.selectedWorktreeId == localSelection)

        // Even clicking an already-selected local destination must close the
        // peer overlay before selectWorktree's early-return guard.
        state.selectWorktree(id: localSelection)
        #expect(client.selectedSessionId == nil)
        #expect(state.selectedWorktreeId == localSelection)
    }
}
