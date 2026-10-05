import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP session fork policy")
struct ACPSessionForkPolicyTests {
    @Test("merge digest excludes inherited conversation and private state, with a readable offset")
    func mergeDigestUsesOnlyPostForkConversation() throws {
        let fork = ACPSessionForkRecord(
            targetSessionID: "fork", sourceSessionID: "source", sourceAgentID: "claude",
            sourceBoundarySequence: 9, inheritedMessageCount: 2,
            phase: .ready, mechanism: .transcriptTransfer, contextDeliveryPending: false
        )
        let messages: [ACPMessage] = [
            .user(id: UUID(), text: " \n", attachments: []),
            .agent(id: UUID(), StreamingText("Inherited answer")),
            .thought(id: UUID(), StreamingText("Private reasoning")),
            .systemNotice(id: UUID(), text: "Internal notice"),
            .user(id: UUID(), text: "Check the retry policy", attachments: []),
            .agent(id: UUID(), StreamingText("Retry only after acknowledgement.")),
        ]
        let prompt = try #require(ACPSessionForkMergeContext.prompt(fork: fork, messages: messages))
        #expect(!prompt.contains("Inherited answer"))
        #expect(!prompt.contains("Private reasoning"))
        #expect(!prompt.contains("Internal notice"))
        #expect(prompt.contains("session_read(session_id: \"fork\", offset: 1)"))
        let json = try #require(prompt.split(separator: "\n").last)
        let entries = try JSONDecoder().decode([ACPSessionTranscriptReader.Entry].self, from: Data(json.utf8))
        #expect(entries.map(\.index) == [2, 3])
        #expect(entries.map(\.text) == ["Check the retry policy", "Retry only after acknowledgement."])
        #expect(ACPSessionForkMergeContext.prompt(fork: fork, messages: Array(messages.prefix(2))) == nil)
        let fallback = try #require(ACPSessionForkMergeContext.prompt(fork: fork, messages: messages, canExpand: false))
        #expect(fallback.contains("complete post-fork conversation"))
        #expect(!fallback.contains("session_read("))
        #expect(fallback.contains("Check the retry policy"))
        #expect(fallback.contains("Retry only after acknowledgement."))
    }

    @Test("merge digest budgets the full escaped prompt and preserves the latest findings",
          arguments: ["a", "\u{01}", "👨‍👩‍👧‍👦\n\"\\"])
    func mergeDigestRespectsBudget(unit: String) throws {
        let fork = ACPSessionForkRecord(
            targetSessionID: "fork", sourceSessionID: "source", sourceAgentID: "codex",
            sourceBoundarySequence: 0, inheritedMessageCount: 0,
            phase: .ready, mechanism: .nativeACP, contextDeliveryPending: false
        )
        let messages = (0..<20).map { index in
            ACPMessage.agent(id: UUID(), StreamingText(String(repeating: unit, count: 3_000) + "Finding \(index)"))
        }
        let prompt = try #require(ACPSessionForkMergeContext.prompt(fork: fork, messages: messages))
        #expect(prompt.count <= ACPSessionForkMergeContext.characterBudget)
        #expect(prompt.contains("Finding 19"))
        #expect(!prompt.contains("Finding 0"))
        let json = try #require(prompt.split(separator: "\n").last)
        let entries = try JSONDecoder().decode([ACPSessionTranscriptReader.Entry].self, from: Data(json.utf8))
        #expect(entries.last?.index == 19)
        #expect(entries.allSatisfy { $0.truncated == true })
        #expect(ACPSessionForkMergeContext.prompt(fork: fork, messages: messages, canExpand: false) == nil)
    }

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

    @Test("attachment-only user messages are not fork boundaries")
    func attachmentOnlyUserMessageIsIneligible() {
        let session = ACPSession(
            id: "source",
            agentId: "claude",
            worktreeId: "wt",
            title: "Source"
        )
        session.transcript.appendMessage(.user(
            id: UUID(),
            text: " \n ",
            attachments: [
                .init(
                    uri: "file:///tmp/image.png",
                    name: "image.png",
                    mimeType: "image/png"
                )
            ]
        ))

        #expect(session.canForkMessage(at: 0) == false)
    }

    @Test("completed agent messages require visible text")
    func completedAgentMessageRequiresVisibleText() {
        let session = ACPSession(
            id: "source",
            agentId: "claude",
            worktreeId: "wt",
            title: "Source"
        )
        session.transcript.messages = [
            .agent(id: UUID(), StreamingText("Answer")),
            .agent(id: UUID(), StreamingText("")),
            .agent(id: UUID(), StreamingText(" \n "))
        ]

        #expect(session.canForkMessage(at: 0))
        #expect(session.canForkMessage(at: 1) == false)
        #expect(session.canForkMessage(at: 2) == false)
    }

    @Test("duplicate enabled agent ids preserve the first catalog definition")
    func duplicateEnabledAgentIDsAreDeduplicated() {
        let targets = ACPForkTargetPolicy.targets(
            sourceAgentID: "claude",
            enabledAgents: [
                .init(id: "claude", displayName: "Claude", logoAssetName: "agent-claude"),
                .init(id: "claude", displayName: "Custom duplicate", logoAssetName: nil)
            ],
            catalogAgentIDs: ["claude"]
        )

        #expect(targets == [
            .init(
                id: "claude",
                displayName: "Claude",
                logoAssetName: "agent-claude",
                isSameAgent: true
            )
        ])
    }

    @Test("an unavailable source agent is not reinserted")
    func unavailableSourceIsNotReinserted() {
        let targets = ACPForkTargetPolicy.targets(
            sourceAgentID: "claude",
            enabledAgents: [
                .init(id: "codex", displayName: "Codex", logoAssetName: "agent-codex")
            ],
            catalogAgentIDs: ["claude", "codex"]
        )

        #expect(targets.map(\.id) == ["codex"])
    }

    enum SideQuestionEntry: Sendable {
        case user(String), agent(String), toolCall
    }

    @Test(
        "side questions fork at the last completed turn",
        arguments: [
            ([SideQuestionEntry.user("q"), .agent("a")], false, Optional(1)),
            ([.user("q"), .agent("a"), .toolCall], false, 1),
            ([.user("q1"), .agent("a1"), .user("q2"), .agent("partial")], true, 1),
            ([.user("q1"), .agent("a1"), .user("q2"), .toolCall], true, 1),
            ([.user("q1"), .agent("a1"), .user("interrupted")], false, 1),
            ([.user("q1"), .agent(""), .user("q2")], true, nil),
            ([.user("q")], true, nil),
            ([], false, nil),
        ] as [([SideQuestionEntry], Bool, Int?)]
    )
    func sideQuestionBoundary(entries: [SideQuestionEntry], isTurnActive: Bool, expectedIndex: Int?) {
        let messages: [ACPMessage] = entries.map {
            switch $0 {
            case .user(let text): .user(id: UUID(), text: text, attachments: [])
            case .agent(let text): .agent(id: UUID(), StreamingText(text))
            case .toolCall: .toolCall(.init(toolCallId: "tc", title: "read", status: "completed", content: "", preview: ""))
            }
        }

        let boundary = ACPSideQuestionBoundaryPolicy.boundary(messages: messages, isTurnActive: isTurnActive)

        #expect(boundary?.stableID == expectedIndex.map { messages[$0].stableId })
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
        guard case .user(_, _, let attachments, let delegatedSource, _) = copiedUser else {
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
