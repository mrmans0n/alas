import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

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

    @Test("queue editing cannot turn an app action into user-authored content", arguments: ["compose", "replace"])
    @MainActor // Queue mutations belong to the main-actor session.
    func editingKeepsAppActionAttribution(action: String) throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "Chat")
        let source = ACPDelegatedPromptSource.shipCreate(kind: .github, branch: "feature", messageID: UUID())
        session.enqueue(blocks: [.text("Open a PR.")], delegatedSource: source)
        let original = try #require(session.queue.first)
        if action == "compose" {
            #expect(session.takeForEditing(id: original.id) == nil)
        } else {
            session.editQueueItem(id: original.id, blocks: [.text("Rewritten instruction")])
        }
        #expect(session.queue == [original])
    }

    @Test("replication preserves app actions and carded Alas turns without treating their origin as a session reference",
          arguments: ["ship", "shepherd"])
    @MainActor // The message codec uses the transcript model.
    func replicaPreservesAppActions(kind: String) throws {
        let writer = try ACPSessionStore(path: ":memory:")
        let reader = try ACPSessionStore(path: ":memory:")
        try writer.upsertSession(.init(id: "writer", agentId: "codex", title: "Chat", autoRun: false,
                                       createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try reader.upsertSession(.init(id: "reader", agentId: "codex", title: "Chat", autoRun: false,
                                       createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try writer.enableReplicaExport(sessionId: "writer", recordId: "record")
        let source = kind == "ship"
            ? ACPDelegatedPromptSource.shipCreate(kind: .github, branch: "feature", messageID: UUID())
            : ACPDelegatedPromptSource.shepherd(
                recordKey: "wt-1", messageID: UUID(),
                card: ACPPromptCard(origin: .shepherd, title: "GitHub #7 · Fix login"))
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

    @Test("a card round-trips with its source, and an app-action-only source gets a header card")
    func cardPersistenceAndLegacyMapping() throws {
        let card = ACPPromptCard(
            origin: .review,
            title: "Review Changes",
            facts: [.init(kind: .repository, text: "alas"), .init(kind: .init(rawValue: "future"), text: "x")],
            sections: [.init(title: "A.swift", items: [
                .init(location: .init(path: "A.swift", startLine: 2, endLine: 2, side: "new"),
                      bodyMarkdown: "Extract helper.", reviewCommentID: "a"),
            ])],
            action: .reviewChanges(worktreeID: "wt")
        )
        let source = ACPDelegatedPromptSource.reviewFeedback(card: card, commentCount: 1, messageID: UUID())
        let restored = try JSONDecoder().decode(ACPDelegatedPromptSource.self, from: JSONEncoder().encode(source))
        #expect(restored == source)
        #expect(ACPPromptCard.resolved(for: restored) == card)
        #expect(ACPDelegatedPromptSource.transcriptLabel(for: restored) { $0 } == "Alas · Address 1 review comment")

        let legacyJSON = #"{"sessionId":"alas:ship","messageId":"m","senderRelationship":"alas-action","appAction":{"title":"Create pull request","source":"Ship"}}"#
        let legacy = try JSONDecoder().decode(ACPDelegatedPromptSource.self, from: Data(legacyJSON.utf8))
        #expect(ACPPromptCard.resolved(for: legacy) == ACPPromptCard(origin: .ship, title: "Create pull request"))
        #expect(ACPPromptCard.resolved(for: ACPDelegatedPromptSource(sessionId: "parent", messageId: "m1")) == nil)
    }
}
