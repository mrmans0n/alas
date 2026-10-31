import Foundation

/// One message between two native sessions (a launch, a SendMessage, a
/// handback), joined from both of its views. The adapter emits the message
/// once on each side, and each view carries the id the OTHER side knows it
/// by, so either half alone is partial. The views can arrive in any order.
public struct ACPDelegationLink: Codable, Equatable, Sendable {
    public let messageId: String
    public var senderSessionId: String?
    public var recipientSessionId: String?
    public var senderMessageId: String?
    public var recipientMessageId: String?

    public init(
        messageId: String, senderSessionId: String?, recipientSessionId: String?,
        senderMessageId: String? = nil, recipientMessageId: String? = nil
    ) {
        self.messageId = messageId
        self.senderSessionId = senderSessionId
        self.recipientSessionId = recipientSessionId
        self.senderMessageId = senderMessageId
        self.recipientMessageId = recipientMessageId
    }

    /// nil for a directed chunk without linked ids (`launchReply`): nothing
    /// on the other side answers to it.
    public init?(messageId: String?, directed: ACPDirectedMessage) {
        guard let messageId, directed.senderMessageId != nil || directed.recipientMessageId != nil else { return nil }
        self.init(
            messageId: messageId,
            senderSessionId: directed.senderSessionId,
            recipientSessionId: directed.recipientSessionId,
            senderMessageId: directed.senderMessageId,
            recipientMessageId: directed.recipientMessageId)
    }

    /// Fills members still nil from `other`; never overwrites a known one.
    public mutating func merge(_ other: ACPDelegationLink) {
        senderSessionId = senderSessionId ?? other.senderSessionId
        recipientSessionId = recipientSessionId ?? other.recipientSessionId
        senderMessageId = senderMessageId ?? other.senderMessageId
        recipientMessageId = recipientMessageId ?? other.recipientMessageId
    }
}

public enum ACPDelegationNavigationTarget: Equatable, Sendable {
    /// The tool call in the root transcript that sent the message.
    case parentToolCall(toolCallId: String)
    /// A child's own row in the parent transcript.
    case subagentRow(subagentSessionId: String)
    /// A row inside a child's transcript.
    case childMessage(subagentSessionId: String, messageId: String)
}

public enum ACPDelegationNavigation {
    /// The other side of `link`, seen from `viewingSessionId`.
    ///
    /// The root never shows a delegation as a row of its own, so from the root
    /// the target is always the child's row for it. From a child that received
    /// the message, the root's sending tool call is the target only while it is
    /// in `parentToolCallIds` (rendered); otherwise the child's own row stands
    /// in. Unknown participants, and a child's view of its own handback to the
    /// root (which has no root row), resolve to nil.
    public static func counterpart(
        of link: ACPDelegationLink, viewingSessionId: String, rootSessionId: String,
        parentToolCallIds: Set<String>, knownChildIds: Set<String>
    ) -> ACPDelegationNavigationTarget? {
        let sender = link.senderSessionId
        let recipient = link.recipientSessionId
        func isChild(_ id: String?) -> Bool { id.map(knownChildIds.contains) ?? false }

        if viewingSessionId == rootSessionId {
            if let recipient, isChild(recipient) {
                return .childMessage(subagentSessionId: recipient, messageId: link.recipientMessageId ?? link.messageId)
            }
            if let sender, isChild(sender), recipient == rootSessionId {
                return .childMessage(subagentSessionId: sender, messageId: link.senderMessageId ?? link.messageId)
            }
            return nil
        }
        guard isChild(viewingSessionId) else { return nil }
        if viewingSessionId == recipient {
            if sender == rootSessionId {
                let toolCallId = link.senderMessageId ?? link.messageId
                return parentToolCallIds.contains(toolCallId)
                    ? .parentToolCall(toolCallId: toolCallId)
                    : .subagentRow(subagentSessionId: viewingSessionId)
            }
            if let sender, isChild(sender) { return .subagentRow(subagentSessionId: sender) }
            return nil
        }
        if viewingSessionId == sender, let recipient, isChild(recipient) {
            return .childMessage(subagentSessionId: recipient, messageId: link.recipientMessageId ?? link.messageId)
        }
        return nil
    }
}
