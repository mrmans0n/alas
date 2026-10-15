import Foundation
import Testing
@testable import AlasCore

struct ACPDelegatedPromptSourceTests {
    @Test("app actions keep their attribution through queue and transcript persistence", arguments: [
        "Create pull request", "Create merge request",
    ])
    @MainActor // Message codec hydration uses the transcript's main-actor message model.
    func persistedAppActionAttribution(title: String) throws {
        let json = #"{"sessionId":"alas:ship","messageId":"action-1","senderRelationship":"alas-action","appAction":{"title":"\#(title)","source":"Ship"}}"#
        let source = try JSONDecoder().decode(ACPDelegatedPromptSource.self, from: Data(json.utf8))
        let queued = QueuedPrompt(blocks: [.text("Open a PR.")], delegatedSource: source)
        let restored = try JSONDecoder().decode(QueuedPrompt.self, from: JSONEncoder().encode(queued))
        #expect(restored.isShownToUser)
        let message = ACPMessage.user(
            id: UUID(), messageId: "action-1", text: "Open a PR.", attachments: [],
            delegatedSource: restored.delegatedSource)
        let wire = try ACPMessageWire.decode(kind: "user", payload: ACPMessageCodec.encode(message))
        guard case .user(_, _, _, _, let persistedSource, _) = wire.toMessage() else {
            Issue.record("Expected the restored request")
            return
        }
        let persisted = try #require(persistedSource)
        #expect(ACPDelegatedPromptSource.transcriptLabel(for: persisted) { $0 } == "Alas · \(title)")
        #expect(persisted.isSameDelivery(as: source))
        #expect(ACPTranscriptMarkdown.document(title: "Chat", agentName: nil, messages: [wire.toMessage()])
            == "# Chat\n\n## Alas · \(title)\n\nOpen a PR.\n")
    }

    @Test("replication preserves app actions without treating their origin as a session reference")
    @MainActor // The message codec uses the transcript model.
    func replicaPreservesAppActions() throws {
        let writer = try ACPSessionStore(path: ":memory:")
        let reader = try ACPSessionStore(path: ":memory:")
        try writer.upsertSession(.init(id: "writer", agentId: "codex", title: "Chat", autoRun: false,
                                       createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try reader.upsertSession(.init(id: "reader", agentId: "codex", title: "Chat", autoRun: false,
                                       createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try writer.enableReplicaExport(sessionId: "writer", recordId: "record")
        let source = ACPDelegatedPromptSource.shipCreate(kind: .github, messageID: UUID())
        let message = ACPMessage.user(
            id: UUID(), messageId: nil, text: "Open a PR.", attachments: [], delegatedSource: source)
        try writer.appendMessage(sessionId: "writer", id: "request", kind: message.kind, seq: 0,
                                 payload: ACPMessageCodec.encode(message), createdAt: 1)
        try writer.upsertQueue(sessionId: "writer", items: [.init(blocks: [.text("Open a PR.")], delegatedSource: source)])
        let exported = try #require(try writer.replicaChanges(sessionId: "writer", limit: 256))
        let entries = exported.entries.map { RemoteSessionReplicaEntry(kind: $0.kind, key: $0.key, payload: $0.payload, revision: 1) }
        try reader.stageReplicaPage(sessionId: "reader", recordId: "record",
                                    page: .init(cutoffRevision: 1, entries: entries, nextPageToken: nil))
        _ = try reader.commitReplicaImport(importGuard: .init(sessionId: "reader", expectedLocalFence: nil))
        #expect(try reader.loadQueue(sessionId: "reader").first?.delegatedSource == source)
        let stored = try #require(try reader.loadMessages(sessionId: "reader").first)
        guard case .user(_, _, _, let restoredSource, _) = try ACPMessageWire.decode(kind: stored.kind, payload: stored.payload) else {
            Issue.record("Expected a replicated app action")
            return
        }
        #expect(restoredSource == source)
    }
}
