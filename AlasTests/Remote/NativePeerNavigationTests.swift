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

    @Test func structuredMessagesExposeUsefulContentWithoutRawJSON() throws {
        let tool = ACPMessage.ToolCall(toolCallId: "tool-1", title: "Run checks",
                                       status: "completed", content: "All checks passed")
        let toolJSON = String(decoding: try JSONEncoder().encode(tool), as: UTF8.self)
        let toolPresentation = NativePeerMessagePresentation(message: .init(
            stableId: "m1", kind: "toolCall", text: nil, json: toolJSON, index: 1
        ))
        #expect(toolPresentation.title.contains("Run checks"))
        #expect(toolPresentation.body.contains("All checks passed"))
        #expect(!toolPresentation.body.contains("toolCallId"))

        let edit = ACPMessage.FileEdit(path: "Sources/App.swift", added: 2, removed: 1,
                                       newText: "let ready = true")
        let editJSON = String(decoding: try JSONEncoder().encode(edit), as: UTF8.self)
        let editPresentation = NativePeerMessagePresentation(message: .init(
            stableId: "m2", kind: "fileEdit", text: nil, json: editJSON, index: 2
        ))
        #expect(editPresentation.body.contains("Sources/App.swift"))
        #expect(editPresentation.body.contains("+2"))
    }

    @Test func peerRowIdentifiesAgentWorktreeAndAttentionState() {
        let worktree = RemoteWorktreeSummary(
            projectName: "Alas", worktreeName: "federation", branch: "feature/peer",
            path: "/repo/federation", metricsAvailable: false, comparisonRef: nil,
            commitCount: 0, changedFileCount: 0, addedLines: 0, deletedLines: 0,
            conflictCount: 0
        )
        let row = RemoteSessionSummary(id: "B:s", title: "Review", agentId: "claude",
                                       status: "awaitingPermission", canDrive: false,
                                       worktree: worktree, serverId: "B", serverName: "Mac B")
        let presentation = NativePeerSessionRowPresentation(row: row)
        #expect(presentation.detail.contains("claude"))
        #expect(presentation.detail.contains("federation"))
        #expect(presentation.detail.contains("Needs permission"))
    }
}
