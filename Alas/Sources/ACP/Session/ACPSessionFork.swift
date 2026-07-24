import Foundation

struct ACPForkMessageBoundary: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case user
        case agent
    }

    let stableID: String
    let kind: Kind
}

struct ACPSessionForkTarget: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let isSameAgent: Bool
}

enum ACPSessionForkCreationPhase: String, Codable, Equatable, Sendable {
    case negotiatingNative
    case ready
}

enum ACPSessionForkMechanism: String, Codable, Equatable, Sendable {
    case nativeACP
    case transcriptTransfer
}

struct ACPSessionForkRecord: Equatable, Sendable {
    let targetSessionID: String
    let sourceSessionID: String
    let sourceAgentID: String
    let sourceBoundarySequence: Int64
    let inheritedMessageCount: Int
    var phase: ACPSessionForkCreationPhase
    var mechanism: ACPSessionForkMechanism?
    var contextDeliveryPending: Bool
}

enum ACPSessionForkCandidate: Equatable {
    case native
    case transcript
}

enum ACPSessionForkCandidatePolicy {
    static func candidate(
        sourceAgentID: String,
        targetAgentID: String,
        boundaryIsRemoteHead: Bool,
        sourceRemoteSessionID: String?,
        forkCapability: Bool?
    ) -> ACPSessionForkCandidate {
        guard sourceAgentID == targetAgentID,
              boundaryIsRemoteHead,
              sourceRemoteSessionID?.isEmpty == false,
              forkCapability != false
        else { return .transcript }

        return .native
    }
}

struct ACPSessionForkConversationMessage: Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case user
        case agent
    }

    let role: Role
    let text: String
}

struct ACPSessionForkSnapshot: Equatable, Sendable {
    let sourceBoundarySequence: Int64
    let messages: [ACPSessionForkConversationMessage]

    func copiedMessages(targetSessionID: String, createdAt: Int64) throws -> [ACPStoredMessage] {
        try messages.enumerated().map { index, message in
            let kind: String
            let payload: Data

            switch message.role {
            case .user:
                kind = "user"
                payload = try JSONEncoder().encode(CopiedUserPayload(
                    messageId: nil,
                    text: message.text,
                    attachments: [],
                    delegatedSource: nil
                ))
            case .agent:
                kind = "agent"
                payload = try JSONEncoder().encode(CopiedTextPayload(
                    messageId: nil,
                    text: message.text
                ))
            }

            return ACPStoredMessage(
                id: "msg-\(targetSessionID)-\(index)",
                sessionId: targetSessionID,
                kind: kind,
                seq: Int64(index),
                payload: payload,
                createdAt: createdAt
            )
        }
    }
}

enum ACPSessionForkSnapshotError: Error, Equatable {
    case boundaryNotFound
    case transcriptMismatch
}

enum ACPSessionForkSnapshotResolver {
    @MainActor
    static func resolve(
        boundary: ACPForkMessageBoundary,
        liveMessages: [ACPMessage],
        storedMessages: [ACPStoredMessage]
    ) throws -> ACPSessionForkSnapshot {
        guard let boundaryIndex = liveMessages.firstIndex(where: { message in
            message.stableId == boundary.stableID && message.forkBoundaryKind == boundary.kind
        }) else {
            throw ACPSessionForkSnapshotError.boundaryNotFound
        }

        guard storedMessages.count == liveMessages.count else {
            throw ACPSessionForkSnapshotError.transcriptMismatch
        }

        let decoder = JSONDecoder()
        let decoded = try storedMessages.map {
            try ACPMessageWire.decode(kind: $0.kind, payload: $0.payload, decoder: decoder)
        }

        for index in 0...boundaryIndex {
            guard matches(liveMessages[index], decoded[index]) else {
                throw ACPSessionForkSnapshotError.transcriptMismatch
            }
        }

        let conversation = decoded[0...boundaryIndex].compactMap { wire -> ACPSessionForkConversationMessage? in
            switch wire {
            case .user(_, let text, _, _):
                text.isEmpty ? nil : .init(role: .user, text: text)
            case .agent(_, let text):
                text.isEmpty ? nil : .init(role: .agent, text: text)
            case .thought, .toolCall, .fileEdit, .plan, .systemNotice:
                nil
            }
        }

        return ACPSessionForkSnapshot(
            sourceBoundarySequence: storedMessages[boundaryIndex].seq,
            messages: conversation
        )
    }

    @MainActor
    private static func matches(_ live: ACPMessage, _ stored: ACPMessageWire) -> Bool {
        switch (live, stored) {
        case let (.user(_, liveMessageID, liveText, _, _), .user(storedMessageID, storedText, _, _)):
            liveMessageID == storedMessageID && liveText == storedText
        case let (.agent(_, liveMessageID, liveText), .agent(storedMessageID, storedText)):
            liveMessageID == storedMessageID && liveText.value == storedText
        case let (.thought(_, liveMessageID, liveText), .thought(storedMessageID, storedText)):
            liveMessageID == storedMessageID && liveText.value == storedText
        case let (.toolCall(liveCall), .toolCall(storedCall)):
            liveCall.toolCallId == storedCall.toolCallId
        case (.fileEdit, .fileEdit), (.plan, .plan), (.systemNotice, .systemNotice):
            true
        default:
            false
        }
    }
}

private extension ACPMessage {
    var forkBoundaryKind: ACPForkMessageBoundary.Kind? {
        switch self {
        case .user:
            .user
        case .agent:
            .agent
        case .thought, .toolCall, .fileEdit, .plan, .systemNotice:
            nil
        }
    }
}

private struct CopiedTextPayload: Codable {
    let messageId: String?
    let text: String
}

private struct CopiedUserPayload: Codable {
    let messageId: String?
    let text: String
    let attachments: [ACPMessage.Attachment]
    let delegatedSource: ACPDelegatedPromptSource?
}
