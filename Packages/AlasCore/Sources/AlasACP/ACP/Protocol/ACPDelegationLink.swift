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
    /// Any participant that is not in `knownChildIds` is the root: context
    /// recovery gives the root a new session id, and links recorded before it
    /// still name the old one. That includes the viewer, so the root's own view
    /// needs no id of its own.
    ///
    /// The root never shows a delegation as a row of its own, so from the root
    /// the target is always the child's row for it. From a child that received
    /// the message from the root, the root's sending tool call is the target
    /// only while it is in `parentToolCallIds` (rendered); otherwise the
    /// child's own row stands in. A message between two children leads to the
    /// other child's copy of it, in either direction. A missing participant,
    /// and a child's view of its own handback to the root (which has no root
    /// row), resolve to nil.
    public static func counterpart(
        of link: ACPDelegationLink, viewingSessionId: String,
        parentToolCallIds: Set<String>, knownChildIds: Set<String>
    ) -> ACPDelegationNavigationTarget? {
        let sender = link.senderSessionId
        let recipient = link.recipientSessionId
        let senderChild = sender.flatMap { knownChildIds.contains($0) ? $0 : nil }
        let recipientChild = recipient.flatMap { knownChildIds.contains($0) ? $0 : nil }
        let senderCopy = link.senderMessageId ?? link.messageId
        let recipientCopy = link.recipientMessageId ?? link.messageId

        guard knownChildIds.contains(viewingSessionId) else {
            if let recipientChild { return .childMessage(subagentSessionId: recipientChild, messageId: recipientCopy) }
            if let senderChild { return .childMessage(subagentSessionId: senderChild, messageId: senderCopy) }
            return nil
        }
        if viewingSessionId == recipient, sender != nil {
            if let senderChild { return .childMessage(subagentSessionId: senderChild, messageId: senderCopy) }
            return parentToolCallIds.contains(senderCopy)
                ? .parentToolCall(toolCallId: senderCopy)
                : .subagentRow(subagentSessionId: viewingSessionId)
        }
        if viewingSessionId == sender, let recipientChild {
            return .childMessage(subagentSessionId: recipientChild, messageId: recipientCopy)
        }
        return nil
    }
}
