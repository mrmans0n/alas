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
    /// Set when the prompt is Alas's own notice about the child named by
    /// `sessionId` (an escalated blocker, a turn without a result, a
    /// failure) rather than a report the child sent: an
    /// `ACPDelegatedOutcomeText.NoticeKind` raw value. A plain string so a
    /// value from a newer build still decodes.
    var childNoticeKind: String? = nil

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
            self.childNoticeKind = ACPDelegatedOutcomeText.noticeKind(ofDelivered: message.prompt)?.rawValue
        }
    }

    init(
        sessionId: String,
        messageId: String,
        senderRelationship: String? = nil,
        senderAgentId: String? = nil,
        childNoticeKind: String? = nil
    ) {
        self.sessionId = sessionId
        self.messageId = messageId
        self.senderRelationship = senderRelationship
        self.senderAgentId = senderAgentId
        self.childNoticeKind = childNoticeKind
    }

    /// Whether both describe the same inbox delivery. Ignores the sender
    /// fields, so a prompt recorded before they existed still dedupes a
    /// redelivery that carries them.
    func isSameDelivery(as other: ACPDelegatedPromptSource) -> Bool {
        sessionId == other.sessionId && messageId == other.messageId
    }

    /// The caption above a delivered prompt in the receiving transcript:
    /// a child's own report, Alas's notice about a child, or a generic
    /// delegated prompt.
    static func transcriptLabel(
        for source: ACPDelegatedPromptSource,
        agentDisplayName: (String) -> String
    ) -> String {
        guard source.isFromChild else { return "Delegated prompt" }
        let shortId = String(source.sessionId.prefix(8))
        let child = source.senderAgentId.flatMap { $0.isEmpty ? nil : agentDisplayName($0) }
            .map { "\($0) child" } ?? "child"
        guard let noticeKind = source.childNoticeKind else {
            return "Report from \(child) · \(shortId)"
        }
        let subject = "Alas · \(child) \(shortId)"
        switch ACPDelegatedOutcomeText.NoticeKind(rawValue: noticeKind) {
        case .needsDecision: return "\(subject) needs a human decision"
        case .noResult: return "\(subject) finished without a result"
        case .failed: return "\(subject) failed"
        case nil: return subject
        }
    }
}
