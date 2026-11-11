import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

/// Sendable, isolation-free intermediate between persisted message bytes
/// and the main-actor `ACPMessage` used by views. The hydrator decodes
/// payloads into `ACPMessageWire` on a background actor; the main hop
/// converts each variant into a full `ACPMessage`, which is the only
/// place we allocate `StreamingText` (a `@MainActor` class).
public enum ACPMessageWire: Sendable, Equatable {
    case user(messageId: String?, text: String, attachments: [ACPMessage.Attachment], delegatedSource: ACPDelegatedPromptSource?, pastedSpans: [ACPPastedTextSpan] = [])
    case agent(messageId: String?, text: String, phase: ACPMessagePhase?, metadata: AnyCodable?)
    case thought(messageId: String?, text: String, phase: ACPMessagePhase?, metadata: AnyCodable?)
    case toolCall(ACPMessage.ToolCall)
    case fileEdit(ACPMessage.FileEdit)
    case plan([ACPMessage.PlanItem])
    case planDocument(ACPPlanDocument)
    case systemNotice(text: String)
    case failureIncident(ACPFailureIncident)
    case visualAid(ACPVisualAid)
    case questionAnswer(ACPAnsweredQuestion)

    public var isAgentSideProgress: Bool {
        switch self {
        case .agent, .thought, .toolCall, .fileEdit, .plan, .planDocument, .visualAid:
            return true
        case .user, .systemNotice, .failureIncident, .questionAnswer:
            return false
        }
    }

    /// Decode a persisted `(kind, payload)` pair into the matching wire variant.
    /// Mirrors `ACPMessageCodec.decode` but produces Sendable values and is
    /// safe to call from any isolation domain. Unknown kinds become system
    /// notices (matching the legacy fallback).
    ///
    /// `decoder` may be a shared instance reused across many calls (e.g. by
    /// `ACPSessionHydrator` when decoding an entire transcript); defaults to
    /// a per-call instance when callers don't care.
    public static func decode(
        kind: String,
        payload: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> ACPMessageWire {
        switch kind {
        case "user":
            let p = try decoder.decode(UserPayload.self, from: payload)
            return .user(messageId: p.messageId, text: p.text, attachments: ACPStoredFileChangeReport.attachments(p.attachments, restoring: p.fileChangeReport), delegatedSource: p.delegatedSource, pastedSpans: p.pastedSpans ?? [])
        case "agent":
            let p = try decoder.decode(TextPayload.self, from: payload)
            return .agent(messageId: p.messageId, text: p.text, phase: ACPMessagePhase.codexPhase(in: p.metadata), metadata: p.metadata)
        case "thought":
            let p = try decoder.decode(TextPayload.self, from: payload)
            return .thought(messageId: p.messageId, text: p.text, phase: ACPMessagePhase.codexPhase(in: p.metadata), metadata: p.metadata)
        case "tool_call":
            return .toolCall(try decoder.decode(ACPMessage.ToolCall.self, from: payload))
        case "file_edit":
            return .fileEdit(try decoder.decode(ACPMessage.FileEdit.self, from: payload))
        case "plan":
            let p = try decoder.decode(ACPPlanRowPayload.self, from: payload)
            return p.document.map(ACPMessageWire.planDocument) ?? .plan(p.items)
        case "visual_aid":
            return .visualAid(try decoder.decode(ACPVisualAid.self, from: payload))
        case "system":
            let p = try decoder.decode(ACPSystemRowPayload.self, from: payload)
            if let answer = p.questionAnswer { return .questionAnswer(answer) }
            return p.failureIncident.map(ACPMessageWire.failureIncident) ?? .systemNotice(text: p.text)
        default:
            return .systemNotice(text: "(unknown message kind: \(kind))")
        }
    }

    /// Convert to a full `ACPMessage`. Must run on the main actor because
    /// `StreamingText` is `@MainActor`-isolated.
    @MainActor
    public func toMessage() -> ACPMessage {
        switch self {
        case .user(let messageId, let text, let attachments, let delegatedSource, let pastedSpans):
            return .user(id: UUID(), messageId: messageId, text: text, attachments: attachments, delegatedSource: delegatedSource, pastedSpans: pastedSpans)
        case .agent(let messageId, let text, let phase, let metadata):
            return .agent(id: UUID(), messageId: messageId, StreamingText(text, phase: phase, metadata: metadata))
        case .thought(let messageId, let text, let phase, let metadata):
            return .thought(id: UUID(), messageId: messageId, StreamingText(text, phase: phase, metadata: metadata))
        case .toolCall(let tc):
            return .toolCall(tc)
        case .fileEdit(let fe):
            return .fileEdit(id: UUID(), fe)
        case .plan(let items):
            return .plan(id: UUID(), items)
        case .planDocument(let document):
            return .planDocument(id: UUID(), document)
        case .systemNotice(let text):
            return .systemNotice(id: UUID(), text: text)
        case .failureIncident(let incident):
            return .failureIncident(id: UUID(), incident)
        case .questionAnswer(let answer):
            return .questionAnswer(answer)
        case .visualAid(let visual):
            return .visualAid(visual)
        }
    }

    /// Materialise a persisted mirror row while retaining the identity of an
    /// already-mounted row at the same transcript position. Unchanged rows
    /// return the existing value, including its `StreamingText` object, so a
    /// mirror refresh does not make the scroller rebuild and remeasure them.
    @MainActor
    public func toMessage(preservingIdentityFrom existing: ACPMessage) -> ACPMessage {
        switch (self, existing) {
        case let (.user(messageId, text, attachments, delegatedSource, pastedSpans),
                  .user(id, existingMessageId, existingText, existingAttachments, existingDelegatedSource, existingPastedSpans)):
            guard messageId != existingMessageId
                    || text != existingText
                    || attachments != existingAttachments
                    || attachments.map(\.symbol) != existingAttachments.map(\.symbol)
                    || delegatedSource != existingDelegatedSource
                    || pastedSpans != existingPastedSpans
            else { return existing }
            return .user(
                id: id,
                messageId: messageId,
                text: text,
                attachments: attachments,
                delegatedSource: delegatedSource,
                pastedSpans: pastedSpans
            )
        case let (.agent(messageId, text, phase, metadata),
                  .agent(id, existingMessageId, existingText)):
            guard messageId != existingMessageId
                    || text != existingText.value
                    || phase != existingText.phase
                    || metadata != existingText.metadata
            else { return existing }
            return .agent(id: id, messageId: messageId, StreamingText(text, phase: phase, metadata: metadata))
        case let (.thought(messageId, text, phase, metadata),
                  .thought(id, existingMessageId, existingText)):
            guard messageId != existingMessageId
                    || text != existingText.value
                    || phase != existingText.phase
                    || metadata != existingText.metadata
            else { return existing }
            return .thought(id: id, messageId: messageId, StreamingText(text, phase: phase, metadata: metadata))
        case let (.toolCall(toolCall), .toolCall(existingToolCall)):
            guard toolCall != existingToolCall else { return existing }
            guard existingToolCall.isContentTruncated,
                  toolCall.status != "in_progress", toolCall.status != "pending"
            else { return .toolCall(toolCall) }
            var truncated = toolCall
            truncated.truncateForOffWindow()
            return .toolCall(truncated)
        case let (.fileEdit(fileEdit), .fileEdit(id, existingFileEdit)):
            return fileEdit == existingFileEdit ? existing : .fileEdit(id: id, fileEdit)
        case let (.plan(items), .plan(id, existingItems)):
            return items == existingItems ? existing : .plan(id: id, items)
        case let (.planDocument(document), .planDocument(id, existingDocument)):
            return document == existingDocument ? existing : .planDocument(id: id, document)
        case let (.systemNotice(text), .systemNotice(id, existingText)):
            return text == existingText ? existing : .systemNotice(id: id, text: text)
        case let (.failureIncident(incident), .failureIncident(id, existingIncident)):
            return incident == existingIncident ? existing : .failureIncident(id: id, incident)
        case let (.questionAnswer(answer), .questionAnswer(existingAnswer)):
            return answer == existingAnswer ? existing : .questionAnswer(answer)
        case let (.visualAid(visual), .visualAid(existingVisual)):
            return visual == existingVisual ? existing : .visualAid(visual)
        default:
            return toMessage()
        }
    }

    private struct TextPayload: Decodable {
        let messageId: String?
        let text: String
        let metadata: AnyCodable?

        public init(messageId: String?, text: String, metadata: AnyCodable?) {
            self.messageId = messageId
            self.text = text
            self.metadata = metadata
        }
    }
    private struct UserPayload: Decodable {
        let messageId: String?
        let text: String
        let attachments: [ACPMessage.Attachment]
        let delegatedSource: ACPDelegatedPromptSource?
        let pastedSpans: [ACPPastedTextSpan]?
        let fileChangeReport: ACPStoredFileChangeReport?
    }
}
