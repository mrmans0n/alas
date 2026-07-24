import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP session fork policy")
struct ACPSessionForkPolicyTests {
    @Test("native candidate requires same agent, remote head, id, and non-negative capability knowledge")
    func nativeCandidateRequirements() {
        #expect(ACPSessionForkCandidatePolicy.candidate(
            sourceAgentID: "claude",
            targetAgentID: "claude",
            boundaryIsRemoteHead: true,
            sourceRemoteSessionID: "remote-1",
            forkCapability: true
        ) == .native)
        #expect(ACPSessionForkCandidatePolicy.candidate(
            sourceAgentID: "claude",
            targetAgentID: "codex",
            boundaryIsRemoteHead: true,
            sourceRemoteSessionID: "remote-1",
            forkCapability: true
        ) == .transcript)
        #expect(ACPSessionForkCandidatePolicy.candidate(
            sourceAgentID: "claude",
            targetAgentID: "claude",
            boundaryIsRemoteHead: false,
            sourceRemoteSessionID: "remote-1",
            forkCapability: true
        ) == .transcript)
        #expect(ACPSessionForkCandidatePolicy.candidate(
            sourceAgentID: "claude",
            targetAgentID: "claude",
            boundaryIsRemoteHead: true,
            sourceRemoteSessionID: nil,
            forkCapability: true
        ) == .transcript)
        #expect(ACPSessionForkCandidatePolicy.candidate(
            sourceAgentID: "claude",
            targetAgentID: "claude",
            boundaryIsRemoteHead: true,
            sourceRemoteSessionID: "remote-1",
            forkCapability: nil
        ) == .native)
    }

    @Test("snapshot is inclusive and conversation-only")
    func conversationOnlySnapshot() throws {
        let user: ACPMessage = .user(
            id: UUID(), messageId: "u1", text: "Question",
            attachments: [.init(uri: "file:///tmp/image.png", name: "image.png", mimeType: "image/png")]
        )
        let tool: ACPMessage = .toolCall(.init(
            toolCallId: "tc1", title: "Read", status: "completed",
            content: "secret tool output", locations: []
        ))
        let agent: ACPMessage = .agent(
            id: UUID(), messageId: "a1", StreamingText("Answer")
        )
        let stored = try [user, tool, agent].enumerated().map { index, message in
            ACPStoredMessage(
                id: "source-\(index)",
                sessionId: "source",
                kind: message.kind,
                seq: Int64(index),
                payload: try ACPMessageCodec.encode(message),
                createdAt: Int64(index)
            )
        }

        let snapshot = try ACPSessionForkSnapshotResolver.resolve(
            boundary: .init(stableID: agent.stableId, kind: .agent),
            liveMessages: [user, tool, agent],
            storedMessages: stored
        )

        #expect(snapshot.sourceBoundarySequence == 2)
        #expect(snapshot.messages == [
            .init(role: .user, text: "Question"),
            .init(role: .agent, text: "Answer")
        ])
        let copied = try snapshot.copiedMessages(targetSessionID: "target", createdAt: 10)
        #expect(copied.map(\.kind) == ["user", "agent"])
        #expect(copied.map(\.seq) == [0, 1])
        let copiedUser = try ACPMessageWire.decode(kind: copied[0].kind, payload: copied[0].payload)
        guard case .user(_, _, let attachments, let delegatedSource) = copiedUser else {
            Issue.record("Expected copied user message")
            return
        }
        #expect(attachments.isEmpty)
        #expect(delegatedSource == nil)
    }

    @Test("snapshot rejects a stale or mismatched boundary")
    func staleBoundaryFails() throws {
        let message: ACPMessage = .user(id: UUID(), text: "live", attachments: [])
        let storedMessage: ACPMessage = .user(id: UUID(), text: "different", attachments: [])
        let stored = ACPStoredMessage(
            id: "m0", sessionId: "source", kind: "user", seq: 0,
            payload: try ACPMessageCodec.encode(storedMessage), createdAt: 0
        )

        #expect(throws: ACPSessionForkSnapshotError.self) {
            _ = try ACPSessionForkSnapshotResolver.resolve(
                boundary: .init(stableID: message.stableId, kind: .user),
                liveMessages: [message],
                storedMessages: [stored]
            )
        }
    }
}
