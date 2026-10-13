import Foundation

public struct ACPDelegatedPromptSource: Codable, Equatable, Sendable {
    public let sessionId: String
    public let messageId: String
    /// How the sender relates to the session the prompt was delivered to.
    /// `"child"` when a delegated child wrote to its parent, `"alas-shepherd"`
    /// for a prompt from Alas's PR shepherd; nil for a parent→child prompt, a
    /// mission prompt, and every source persisted before this field existed.
    /// A plain string so an unknown future value still decodes (and falls
    /// back to the generic label).
    public var senderRelationship: String? = nil
    /// The sender's agent id, recorded with `senderRelationship`.
    public var senderAgentId: String? = nil
    /// Set when the prompt is Alas's own notice about the child named by
    /// `sessionId` (an escalated blocker, a turn without a result, a
    /// failure) rather than a report the child sent: an
    /// `ACPDelegatedOutcomeText.NoticeKind` raw value. A plain string so a
    /// value from a newer build still decodes.
    public var childNoticeKind: String? = nil

    /// Individual inbox identities retained by a combined parent prompt.
    /// Nil for single deliveries and sources saved by older builds.
    public var batchedSources: [ACPDelegatedPromptSource]? = nil

    public var deliveries: [ACPDelegatedPromptSource] { batchedSources ?? [self] }

    public static func batch(_ sources: [ACPDelegatedPromptSource]) -> ACPDelegatedPromptSource {
        let deliveries = sources.flatMap(\.deliveries)
        var source = deliveries[0]
        source.batchedSources = deliveries.count > 1 ? deliveries : nil
        return source
    }

    public static let childRelationship = "child"

    public var isFromChild: Bool { senderRelationship == Self.childRelationship }

    public static let shepherdRelationship = "alas-shepherd"

    /// Queued by Alas's PR shepherd rather than by another session.
    public var isFromShepherd: Bool { senderRelationship == Self.shepherdRelationship }

    /// A prompt the PR shepherd queues for the session that owns a pull or
    /// merge request. `recordKey` (the shepherd record's storage key) names
    /// the sender; every prompt gets its own `messageID`, so two prompts are
    /// never deduplicated as one delivery.
    public static func shepherd(recordKey: String, messageID: UUID) -> ACPDelegatedPromptSource {
        ACPDelegatedPromptSource(
            sessionId: "shepherd:\(recordKey)",
            messageId: messageID.uuidString,
            senderRelationship: shepherdRelationship
        )
    }

    /// The source for an inbox message delivered as a prompt. The sender is
    /// tagged as a child only when `senderDelegation` (the delegation record
    /// whose child is the message's source) names the target as its parent.
    public init(message: ACPDelegatedMessage, senderDelegation: ACPDelegationRecord?) {
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

    public init(
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
    public func isSameDelivery(as other: ACPDelegatedPromptSource) -> Bool {
        deliveries.contains { delivery in
            other.deliveries.contains {
                delivery.sessionId == $0.sessionId && delivery.messageId == $0.messageId
            }
        }
    }

    /// The caption above a delivered prompt in the receiving transcript:
    /// a child's own report, Alas's notice about a child, a PR shepherd
    /// prompt, or a generic delegated prompt.
    public static func transcriptLabel(
        for source: ACPDelegatedPromptSource,
        agentDisplayName: (String) -> String
    ) -> String {
        if let batch = source.batchedSources {
            let count = Set(batch.map(\.sessionId)).count
            return "Updates from \(count) child \(count == 1 ? "session" : "sessions")"
        }
        if source.isFromShepherd { return "Alas PR shepherd" }
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
