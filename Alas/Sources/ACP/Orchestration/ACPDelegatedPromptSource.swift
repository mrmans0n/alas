import Foundation

struct ACPDelegatedPromptSource: Codable, Equatable, Sendable {
    let sessionId: String
    let messageId: String
    /// How the sender relates to the session the prompt was delivered to.
    /// `"child"` when a delegated child wrote to its parent; nil for a
    /// parent→child prompt, a mission prompt, and every source persisted
    /// before this field existed. A plain string so an unknown future value
    /// still decodes (and falls back to the generic label).
    var senderRelationship: String? = nil
    /// The sender's agent id, recorded with `senderRelationship`.
    var senderAgentId: String? = nil

    static let childRelationship = "child"

    var isFromChild: Bool { senderRelationship == Self.childRelationship }

    /// The source for an inbox message delivered as a prompt. The sender is
    /// tagged as a child only when `senderDelegation` (the delegation record
    /// whose child is the message's source) names the target as its parent.
    init(message: ACPDelegatedMessage, senderDelegation: ACPDelegationRecord?) {
        self.sessionId = message.sourceSessionId
        self.messageId = message.id
        if let senderDelegation,
           senderDelegation.childSessionId == message.sourceSessionId,
           senderDelegation.parentSessionId == message.targetSessionId {
            self.senderRelationship = Self.childRelationship
            self.senderAgentId = senderDelegation.agentId
        }
    }

    init(
        sessionId: String,
        messageId: String,
        senderRelationship: String? = nil,
        senderAgentId: String? = nil
    ) {
        self.sessionId = sessionId
        self.messageId = messageId
        self.senderRelationship = senderRelationship
        self.senderAgentId = senderAgentId
    }

    /// Whether both describe the same inbox delivery. Ignores the sender
    /// fields, so a prompt recorded before they existed still dedupes a
    /// redelivery that carries them.
    func isSameDelivery(as other: ACPDelegatedPromptSource) -> Bool {
        sessionId == other.sessionId && messageId == other.messageId
    }

    /// The caption above a delivered prompt in the receiving transcript.
    static func transcriptLabel(
        for source: ACPDelegatedPromptSource,
        agentDisplayName: (String) -> String
    ) -> String {
        guard source.isFromChild else { return "Delegated prompt" }
        let shortId = String(source.sessionId.prefix(8))
        guard let agentId = source.senderAgentId, !agentId.isEmpty else {
            return "Report from child · \(shortId)"
        }
        return "Report from \(agentDisplayName(agentId)) child · \(shortId)"
    }
}
