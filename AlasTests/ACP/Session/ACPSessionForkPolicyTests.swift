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

    nonisolated static let forkTarget = ACPForkPointTarget(
        messageId: "a1", messageFingerprint: ACPForkPointTarget.fingerprint("A1"), messageOccurrence: 1
    )

    @Test(
        "native candidate requires same agent, remote id, and non-negative capability knowledge; an earlier boundary needs the forkPoint advert and a target",
        arguments: [
            ("claude", true, "remote-1", true, false, false, ACPSessionForkCandidate.native),
            ("codex", true, "remote-1", true, false, false, .transcript),
            ("claude", false, "remote-1", true, false, false, .transcript),
            ("claude", true, nil, true, false, false, .transcript),
            ("claude", true, "remote-1", nil, false, false, .native),
            ("claude", false, "remote-1", true, true, true, .nativeAtMessage(ACPSessionForkPolicyTests.forkTarget)),
            ("claude", false, "remote-1", false, true, true, .transcript),
            ("claude", false, "remote-1", true, false, true, .transcript),
            ("claude", false, "remote-1", true, true, false, .transcript),
            ("claude", true, "remote-1", true, true, true, .native),
        ] as [(String, Bool, String?, Bool?, Bool, Bool, ACPSessionForkCandidate)]
    )
    func nativeCandidateRequirements(
        targetAgentID: String,
        boundaryIsRemoteHead: Bool,
        sourceRemoteSessionID: String?,
        forkCapability: Bool?,
        advertisesForkPoint: Bool,
        hasHistoricalTarget: Bool,
        expected: ACPSessionForkCandidate
    ) {
        #expect(ACPSessionForkCandidatePolicy.candidate(
            sourceAgentID: "claude",
            targetAgentID: targetAgentID,
            boundaryIsRemoteHead: boundaryIsRemoteHead,
            sourceRemoteSessionID: sourceRemoteSessionID,
            forkCapability: forkCapability,
            forkPoint: advertisesForkPoint ? .init(boundary: .message) : nil,
            historicalTarget: hasHistoricalTarget ? Self.forkTarget : nil
        ) == expected)
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

    @Test("snapshot is inclusive and conversation-only", arguments: [false, true])
    func conversationOnlySnapshot(keepsProviderMessageIDs: Bool) throws {
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
        let visual: ACPMessage = .visualAid(ACPVisualAid(
            id: UUID(), title: "Layouts", html: "<h2>Pick</h2>", question: nil, answer: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        ))
        let stored = try [user, tool, visual, agent].enumerated().map { index, message in
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
            liveMessages: [user, tool, visual, agent],
            storedMessages: stored
        )

        #expect(snapshot.sourceBoundarySequence == 3)
        #expect(snapshot.messages == [
            .init(role: .user, text: "Question"),
            .init(role: .agent, text: "Answer", messageId: "a1")
        ])
        let copied = try snapshot.copiedMessages(
            targetSessionID: "target", createdAt: 10, keepsProviderMessageIDs: keepsProviderMessageIDs
        )
        #expect(copied.map(\.kind) == ["user", "agent"])
        #expect(copied.map(\.seq) == [0, 1])
        let copiedUser = try ACPMessageWire.decode(kind: copied[0].kind, payload: copied[0].payload)
        guard case .user(let userMessageID, _, let attachments, let delegatedSource, _) = copiedUser else {
            Issue.record("Expected copied user message")
            return
        }
        #expect(userMessageID == nil)
        #expect(attachments.isEmpty)
        #expect(delegatedSource == nil)
        let copiedAgent = try ACPMessageWire.decode(kind: copied[1].kind, payload: copied[1].payload)
        guard case .agent(let agentMessageID, "Answer", _, _) = copiedAgent else {
            Issue.record("Expected copied agent message")
            return
        }
        #expect(agentMessageID == (keepsProviderMessageIDs ? "a1" : nil))
    }

    enum ForkRow: Sendable {
        case user(String)
        case agent(String?, String)
        /// An agent segment cut by a steering follow-up: its continuation
        /// lives in a later row under an `alas-steering:` id.
        case steeringSplitAgent(String, String)
        case tool(String)
    }

    /// Live messages and their stored rows, with `seq == index`.
    static func transcript(_ rows: [ForkRow]) throws -> (live: [ACPMessage], stored: [ACPStoredMessage]) {
        var live: [ACPMessage] = []
        var stored: [ACPStoredMessage] = []
        for (index, row) in rows.enumerated() {
            let message: ACPMessage
            var payload: Data?
            switch row {
            case .user(let text):
                message = .user(id: UUID(), messageId: nil, text: text, attachments: [])
            case .agent(let messageId, let text):
                message = .agent(id: UUID(), messageId: messageId, StreamingText(text))
            case .steeringSplitAgent(let messageId, let text):
                message = .agent(id: UUID(), messageId: messageId, StreamingText(text))
                payload = try JSONSerialization.data(withJSONObject: [
                    "messageId": messageId,
                    "text": text,
                    "metadata": [
                        "_alas/steeringContinuationMessageId": "alas-steering:\(UUID().uuidString)",
                        "_alas/steeringFollowingUserCount": 1,
                    ],
                ])
            case .tool(let toolCallId):
                message = .toolCall(.init(toolCallId: toolCallId, title: "read", status: "completed", content: "", preview: ""))
            }
            live.append(message)
            stored.append(ACPStoredMessage(
                id: "source-\(index)", sessionId: "source", kind: message.kind, seq: Int64(index),
                payload: try payload ?? ACPMessageCodec.encode(message), createdAt: Int64(index)
            ))
        }
        return (live, stored)
    }

    static func boundary(_ live: [ACPMessage], at index: Int) throws -> ACPForkMessageBoundary {
        .init(stableID: live[index].stableId, kind: try #require(live[index].forkBoundaryKind))
    }

    @Test(
        "only a completed, unsplit agent message with a provider id is a fork point target",
        arguments: [
            ("next turn", [ForkRow.user("u"), .agent("a1", "A1"), .user("u2"), .agent("a2", "A2")], 1, false, 0, true),
            ("tool tail", [.user("u"), .agent("a1", "A1"), .tool("tc1"), .user("u2")], 1, false, 0, true),
            ("mid turn", [.user("u"), .agent("a1", "A1"), .tool("tc1"), .agent("a2", "A2"), .user("u2")], 1, false, 0, false),
            ("no id", [.user("u"), .agent(nil, "A1"), .user("u2")], 1, false, 0, false),
            ("steering id", [.user("u"), .agent("alas-steering:\(UUID().uuidString)", "A1"), .user("u2")], 1, false, 0, false),
            ("steering split", [.user("u"), .steeringSplitAgent("a1", "A1"), .user("u2"), .agent("a1b", "rest")], 1, false, 0, false),
            ("user boundary", [.user("u"), .agent("a1", "A1"), .user("u2"), .agent("a2", "A2")], 0, false, 0, false),
            ("unpersisted tail", [.user("u"), .agent("a1", "A1"), .user("u2"), .agent("a2", "A2")], 1, true, 0, false),
            ("inherited by transcript", [.user("u"), .agent("a1", "A1"), .user("u2"), .agent("a2", "A2")], 1, false, 2, false),
        ] as [(String, [ForkRow], Int, Bool, Int, Bool)]
    )
    func forkPointTargetEligibility(
        label: String, rows: [ForkRow], boundaryIndex: Int,
        allowsUnpersistedTail: Bool, remoteHistoryStart: Int, eligible: Bool
    ) throws {
        let (live, stored) = try Self.transcript(rows)

        let snapshot = try ACPSessionForkSnapshotResolver.resolve(
            boundary: try Self.boundary(live, at: boundaryIndex),
            liveMessages: live,
            storedMessages: stored,
            allowsUnpersistedTail: allowsUnpersistedTail,
            remoteHistoryStart: remoteHistoryStart
        )

        #expect(snapshot.forkPointTarget == (eligible ? Self.forkTarget : nil))
    }

    @Test(
        "a fork point counts equal agent text only in the history the agent holds, once per adapter message",
        arguments: [
            ([ForkRow.user("q1"), .agent("a1", "Same"), .user("q2"), .agent("a2", "Same"), .user("q3"), .agent("a3", "Other")], 3, 0, 2),
            ([.user("q1"), .agent("a1", "Same"), .user("q2"), .agent("a2", "Same"), .user("q3"), .agent("a3", "Other")], 3, 2, 1),
            // Steering segments are parts of one adapter message, not messages.
            ([.user("q1"), .steeringSplitAgent("a0", "Same"), .user("s"), .agent("alas-steering:\(UUID().uuidString)", "Same"), .user("q2"), .agent("a2", "Same")], 5, 0, 1),
        ] as [([ForkRow], Int, Int, Int)]
    )
    func forkPointOccurrence(rows: [ForkRow], boundaryIndex: Int, remoteHistoryStart: Int, occurrence: Int) throws {
        let (live, stored) = try Self.transcript(rows)

        let snapshot = try ACPSessionForkSnapshotResolver.resolve(
            boundary: try Self.boundary(live, at: boundaryIndex),
            liveMessages: live,
            storedMessages: stored,
            remoteHistoryStart: remoteHistoryStart
        )

        #expect(snapshot.forkPointTarget == ACPForkPointTarget(
            messageId: "a2", messageFingerprint: ACPForkPointTarget.fingerprint("Same"), messageOccurrence: occurrence
        ))
    }

    @Test(
        "the source check lists later item ids only while the targeted row is unchanged",
        arguments: [
            ("advanced", "a1", "A1", Int64(1), ACPForkPointBoundary.message, Optional(Set(["tc1", "a2", "tc9"]))),
            // The tool call that ends the targeted turn is part of a turn fork.
            ("turn tool tail", "a1", "A1", 1, .turn, Set(["a2", "tc9"])),
            ("edited text", "a1", "A1 edited", 1, .message, nil),
            ("changed id", "a1-new", "A1", 1, .message, nil),
            ("missing row", "a1", "A1", 99, .turn, nil),
        ] as [(String, String, String, Int64, ACPForkPointBoundary, Set<String>?)]
    )
    func forkPointSourceCheck(
        label: String, boundaryMessageID: String, boundaryText: String,
        boundarySequence: Int64, boundary: ACPForkPointBoundary, expected: Set<String>?
    ) throws {
        let (_, stored) = try Self.transcript([
            .user("u"), .agent(boundaryMessageID, boundaryText), .tool("tc1"), .user("u2"), .agent("a2", "A2"), .tool("tc9"),
        ])

        #expect(try ACPSessionForkSourceCheck.laterItemIDs(
            storedMessages: stored, boundarySequence: boundarySequence, target: Self.forkTarget, boundary: boundary
        ) == expected)
    }

    @Test(
        "a fork point echo must land on the target and not on later source items",
        arguments: [
            ("no echo", nil, "msg_1", ACPForkPointBoundary.message, Optional(ACPForkPointFailure.missingEcho)),
            ("claude id", ACPForkPointEcho(boundary: .message, messageId: "msg_1", matchedBy: .id), "msg_1", .message, nil),
            ("claude segment", ACPForkPointEcho(boundary: .message, messageId: "msg_1", matchedBy: .id), "msg_1:segment:2", .message, nil),
            ("wrong id", ACPForkPointEcho(boundary: .message, messageId: "msg_0", matchedBy: .id), "msg_1", .message, .mismatchedEcho),
            ("fingerprint new id", ACPForkPointEcho(boundary: .message, messageId: "msg_9", matchedBy: .fingerprint), "msg_1", .message, nil),
            ("fingerprint later id", ACPForkPointEcho(boundary: .message, messageId: "a2", matchedBy: .fingerprint), "msg_1", .message, .mismatchedEcho),
            ("codex turn", ACPForkPointEcho(boundary: .turn, messageId: "msg_1", turnId: "t1", lastItemId: "i1", matchedBy: .id), "msg_1", .turn, nil),
            ("codex later item", ACPForkPointEcho(boundary: .turn, messageId: "msg_1", turnId: "t1", lastItemId: "i9", matchedBy: .id), "msg_1", .turn, .mismatchedEcho),
            ("codex no turn", ACPForkPointEcho(boundary: .turn, messageId: "msg_1", lastItemId: "i1", matchedBy: .id), "msg_1", .turn, .mismatchedEcho),
            ("message for turn", ACPForkPointEcho(boundary: .message, messageId: "msg_1", matchedBy: .id), "msg_1", .turn, .mismatchedEcho),
            ("fingerprint later segment", ACPForkPointEcho(boundary: .message, messageId: "msg_1", matchedBy: .fingerprint), "msg_1", .message, .mismatchedEcho),
        ] as [(String, ACPForkPointEcho?, String, ACPForkPointBoundary, ACPForkPointFailure?)]
    )
    func forkPointVerification(
        label: String, echo: ACPForkPointEcho?, targetMessageID: String,
        boundary: ACPForkPointBoundary, failure: ACPForkPointFailure?
    ) throws {
        let target = ACPForkPointTarget(
            messageId: targetMessageID, messageFingerprint: ACPForkPointTarget.fingerprint("A1"), messageOccurrence: 1
        )

        let result = ACPForkPointVerifier.verify(
            echo: echo, target: target, boundary: boundary, laterSourceItemIDs: ["a2", "i9", "msg_1:segment:3"]
        )

        if let failure {
            #expect(result == .failure(failure))
        } else {
            #expect(result == .success(try #require(echo)))
        }
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
