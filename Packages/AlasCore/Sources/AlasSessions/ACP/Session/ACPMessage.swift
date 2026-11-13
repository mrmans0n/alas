import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

public enum ACPMessage: Equatable, Sendable {
    case user(id: UUID, messageId: String?, text: String, attachments: [Attachment], delegatedSource: ACPDelegatedPromptSource? = nil, pastedSpans: [ACPPastedTextSpan] = [])
    case agent(id: UUID, messageId: String?, StreamingText)
    case thought(id: UUID, messageId: String?, StreamingText)
    case toolCall(ToolCall)
    case fileEdit(id: UUID, FileEdit)
    case plan(id: UUID, [PlanItem])
    /// A Markdown or file plan. Persisted under the `"plan"` kind, but never a
    /// checklist: the plan pill, `currentPlan` and summaries ignore it.
    case planDocument(id: UUID, ACPPlanDocument)
    case systemNotice(id: UUID, text: String)
    /// Persisted under the `"system"` kind, with the title as its text.
    case failureIncident(id: UUID, ACPFailureIncident)
    case visualAid(ACPVisualAid)
    case questionAnswer(ACPAnsweredQuestion)
    /// Persisted under the `"system"` kind, with its text as the notice text.
    case outcomeCard(ACPOutcomeCard)

    public static func user(id: UUID, text: String, attachments: [Attachment]) -> ACPMessage {
        .user(id: id, messageId: nil, text: text, attachments: attachments)
    }

    public static func agent(id: UUID, _ text: StreamingText) -> ACPMessage {
        .agent(id: id, messageId: nil, text)
    }

    public static func thought(id: UUID, _ text: StreamingText) -> ACPMessage {
        .thought(id: id, messageId: nil, text)
    }

    public enum StableIdentityKey: Hashable, Codable, Sendable {
        case userMessageId(String)
        case agentMessageId(String)
        case thoughtMessageId(String)
        case userUUID(UUID)
        case agentUUID(UUID)
        case thoughtUUID(UUID)
        case fileEdit(UUID)
        case plan(UUID)
        case systemNotice(UUID)
        case failureIncident(UUID)
        case visualAid(UUID)
        case questionAnswer(UUID)
        case outcomeCard(UUID)
        case toolCall(String)
    }

    public var stableIdentityKey: StableIdentityKey {
        switch self {
        case .user(let id, let messageId, _, _, _, _):
            messageId.map(StableIdentityKey.userMessageId) ?? .userUUID(id)
        case .agent(let id, let messageId, _):
            messageId.map(StableIdentityKey.agentMessageId) ?? .agentUUID(id)
        case .thought(let id, let messageId, _):
            messageId.map(StableIdentityKey.thoughtMessageId) ?? .thoughtUUID(id)
        case .fileEdit(let id, _):
            .fileEdit(id)
        case .plan(let id, _), .planDocument(let id, _):
            .plan(id)
        case .systemNotice(let id, _):
            .systemNotice(id)
        case .failureIncident(let id, _):
            .failureIncident(id)
        case .questionAnswer(let answer):
            .questionAnswer(answer.id)
        case .outcomeCard(let card):
            .outcomeCard(card.id)
        case .visualAid(let visual):
            .visualAid(visual.id)
        case .toolCall(let tc):
            .toolCall(tc.toolCallId)
        }
    }

    public var stableId: String {
        Self.stableId(for: stableIdentityKey)
    }

    /// The notice recorded in place of a restart continuation's user row.
    public var isInterruptedTurnContinuationNotice: Bool {
        if case .systemNotice(_, QueuedPrompt.interruptedTurnContinueNotice) = self { true } else { false }
    }

    /// Mirrors `ACPMessageWire.isAgentSideProgress`.
    public var isAgentSideProgress: Bool {
        switch self {
        case .agent, .thought, .toolCall, .fileEdit, .plan, .planDocument, .visualAid:
            true
        case .user, .systemNotice, .failureIncident, .questionAnswer, .outcomeCard:
            false
        }
    }

    public static func stableId(for key: StableIdentityKey) -> String {
        switch key {
        case .userMessageId(let messageId):
            "acp-user:\(messageId)"
        case .agentMessageId(let messageId):
            "acp-agent:\(messageId)"
        case .thoughtMessageId(let messageId):
            "acp-thought:\(messageId)"
        case .userUUID(let id), .agentUUID(let id), .thoughtUUID(let id),
             .fileEdit(let id), .plan(let id), .systemNotice(let id), .failureIncident(let id), .visualAid(let id), .questionAnswer(let id),
             .outcomeCard(let id):
            id.uuidString
        case .toolCall(let toolCallId):
            "tc-\(toolCallId)"
        }
    }

    @MainActor
    public var contentUTF8Length: Int {
        switch self {
        case .user(_, _, let text, _, _, _):
            text.utf8.count
        case .agent(_, _, let text), .thought(_, _, let text):
            text.utf8Length
        case .systemNotice(_, let text):
            text.utf8.count
        case .failureIncident(_, let incident):
            incident.displayText.utf8.count
        case .toolCall(let tc):
            tc.content.utf8.count
        case .questionAnswer(let answer):
            answer.displayText.utf8.count
        case .outcomeCard(let card):
            card.text.utf8.count
        case .visualAid(let visual):
            visual.title.utf8.count + visual.html.utf8.count
        case .fileEdit, .plan, .planDocument:
            0
        }
    }

    public var kind: String {
        switch self {
        case .user: "user"
        case .agent: "agent"
        case .thought: "thought"
        case .toolCall: "tool_call"
        case .fileEdit: "file_edit"
        case .plan, .planDocument: "plan"
        case .systemNotice, .failureIncident, .questionAnswer, .outcomeCard: "system"
        case .visualAid: "visual_aid"
        }
    }

    public struct Attachment: Codable, Equatable, Hashable, Sendable {
        private static let checkpointReferencePrefix = "alas-checkpoint://"
        private static let fileChangeReportReferencePrefix = "alas-file-change-report://"

        public let uri: String
        public let name: String?
        /// Image MIME type (e.g. `image/png`) when this attachment is an
        /// image; `nil` for mention/resource-link attachments. Drives
        /// thumbnail rendering in the user bubble. Synthesized Codable
        /// decodes a missing key as nil, so legacy rows stay valid.
        public let mimeType: String?
        /// Character offset into the sibling message's `text` where this
        /// image chip sat in the composer, used to place an inline marker
        /// in the transcript bubble at the exact spot (see
        /// `ACPUserMessageImageMarkers`). Populated from
        /// `ACPComposerDraft.imageTextOffsets()` when a captured draft is
        /// available; `nil` for legacy rows, agent-echoed attachments, and
        /// queue items restored via the lossy `blocks`-only heuristic — the
        /// bubble then shows no inline marker, only the summary thumbnails.
        ///
        /// Deliberately excluded from `==`/`hash(into:)` below: it is
        /// positional UI metadata, not part of the attachment's identity,
        /// and an agent-echoed copy of the same attachment never carries it
        /// — including it in equality would make local/echoed reconciliation
        /// in `ACPSession.appendUserChunk` spuriously treat identical
        /// attachments as different.
        public let textOffset: Int?

        /// Symbol mentions only: what was sent (see `ACPSymbolReference`).
        /// Absent in legacy rows. Excluded from `==`/`hash(into:)` like
        /// `textOffset`, so an agent-echoed copy still reconciles.
        public let symbol: ACPSymbolSnapshot?

        /// Report references only: the report that landed for the turn, nil
        /// while it is only requested. Stored in the user payload's own
        /// `fileChangeReport` key, never in `attachments`, so this is not
        /// coded here. Part of `==`, unlike `textOffset` and `symbol`: an
        /// agent's echo never carries one, and a report landing has to read
        /// as a changed row.
        public let fileChangeReport: ACPAgentFileChangeReport?

        private enum CodingKeys: String, CodingKey {
            case uri, name, mimeType, textOffset, symbol
        }

        public init(uri: String, name: String?, mimeType: String? = nil, textOffset: Int? = nil,
             symbol: ACPSymbolSnapshot? = nil, fileChangeReport: ACPAgentFileChangeReport? = nil) {
            self.uri = uri
            self.name = name
            self.mimeType = mimeType
            self.textOffset = textOffset
            self.symbol = symbol
            self.fileChangeReport = fileChangeReport
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uri = try c.decode(String.self, forKey: .uri)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
            textOffset = try c.decodeIfPresent(Int.self, forKey: .textOffset)
            symbol = try c.decodeIfPresent(ACPSymbolSnapshot.self, forKey: .symbol)
            fileChangeReport = nil
        }

        public static func checkpointReference(id: CheckpointID) -> Self {
            .init(uri: checkpointReferencePrefix + id.uuidString, name: nil)
        }

        public var checkpointID: CheckpointID? {
            guard uri.hasPrefix(Self.checkpointReferencePrefix) else { return nil }
            return UUID(uuidString: String(uri.dropFirst(Self.checkpointReferencePrefix.count)))
        }

        public var isCheckpointReference: Bool { checkpointID != nil }

        /// `uri` is "alas-file-change-report://<requestId>".
        public static func fileChangeReportReference(requestId: String, report: ACPAgentFileChangeReport? = nil) -> Self {
            assert(ACPAgentFileChangeReport.isValidRequestId(requestId), "Invalid request id")
            assert(report.map { $0.requestId == requestId } ?? true, "Report answers another request")
            return .init(uri: fileChangeReportReferencePrefix + requestId, name: nil, fileChangeReport: report)
        }

        public var fileChangeReportRequestId: String? {
            guard uri.hasPrefix(Self.fileChangeReportReferencePrefix) else { return nil }
            let requestId = String(uri.dropFirst(Self.fileChangeReportReferencePrefix.count))
            return ACPAgentFileChangeReport.isValidRequestId(requestId) ? requestId : nil
        }

        /// Checkpoint and report references: Alas bookkeeping, not something the user attached.
        public var isLocalReference: Bool { isCheckpointReference || fileChangeReportRequestId != nil }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.uri == rhs.uri && lhs.name == rhs.name && lhs.mimeType == rhs.mimeType
                && lhs.fileChangeReport == rhs.fileChangeReport
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(uri)
            hasher.combine(name)
            hasher.combine(mimeType)
        }
    }

    public typealias ToolCallAsset = ACPToolCallAsset
    public typealias ToolCall = ACPToolCall
    public typealias FileEdit = ACPFileEdit
    public typealias PlanItem = ACPPlanItem
}

extension ACPMessage {
    /// Symbol snapshots of a user message's attachments, in order. `Attachment`
    /// equality ignores them so an agent's echo still reconciles, which makes
    /// `==` blind to a re-stamped snapshot.
    public var symbolSnapshots: [ACPSymbolSnapshot?] {
        guard case .user(_, _, _, let attachments, _, _) = self else { return [] }
        return attachments.map(\.symbol)
    }

    /// `==` plus the symbol snapshots, for deciding whether a mirror refresh
    /// has anything new to show.
    public func matches(_ other: ACPMessage) -> Bool {
        self == other && symbolSnapshots == other.symbolSnapshots
    }
}

/// The documented, versioned context-compaction facts carried on a synthetic
/// tool call. Unknown metadata is intentionally not projected into the UI.
public struct ACPContextCompaction: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case inProgress
        case completed
        case failed
        case cancelled
        case other(String)
    }

    public let id: String
    public let status: Status
    public let trigger: String?
    public let tokensBefore: Int?
    public let tokensAfter: Int?
    public let durationMs: Int?
    public let error: String?

    public init?(toolCall: ACPMessage.ToolCall) {
        guard let root = Self.object(toolCall.metadata),
              let raw = root["contextCompaction"],
              let compaction = Self.object(raw),
              Self.int(compaction["version"]) == 1 else {
            return nil
        }
        id = Self.string(compaction["id"]) ?? toolCall.toolCallId
        status = Self.status(toolCall.status)
        trigger = Self.string(compaction["trigger"])
        tokensBefore = Self.int(compaction["preTokens"])
        tokensAfter = Self.int(compaction["postTokens"])
        durationMs = Self.int(compaction["durationMs"])
        error = Self.string(compaction["error"])
    }

    private static func object(_ value: AnyCodable?) -> [String: AnyCodable]? {
        value.flatMap(object)
    }

    private static func object(_ value: AnyCodable) -> [String: AnyCodable]? {
        if let object = value.value as? [String: AnyCodable] { return object }
        if let object = value.value as? [String: Any] {
            return object.mapValues { AnyCodable($0) }
        }
        return nil
    }

    private static func string(_ value: AnyCodable?) -> String? {
        value?.value as? String
    }

    private static func int(_ value: AnyCodable?) -> Int? {
        value?.value as? Int
    }

    private static func status(_ raw: String) -> Status {
        switch raw {
        case "in_progress", "running": .inProgress
        case "completed", "success": .completed
        case "failed", "error": .failed
        case "cancelled", "canceled": .cancelled
        default: .other(raw)
        }
    }
}

public enum ACPMessageCodec: Sendable {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    @MainActor
    public static func encode(_ m: ACPMessage) throws -> Data {
        switch m {
        case .user(_, let messageId, let text, let atts, let delegatedSource, let pastedSpans): return try encoder.encode(UserPayload(messageId: messageId, text: text, attachments: atts.filter { $0.fileChangeReportRequestId == nil }, delegatedSource: delegatedSource, pastedSpans: pastedSpans.isEmpty ? nil : pastedSpans, fileChangeReport: .init(attachments: atts)))
        case .agent(_, let messageId, let buf):            return try encoder.encode(TextPayload(messageId: messageId, text: buf.value, metadata: buf.metadata))
        case .thought(_, let messageId, let buf):          return try encoder.encode(TextPayload(messageId: messageId, text: buf.value, metadata: buf.metadata))
        case .toolCall(let tc):             return try encoder.encode(tc)
        case .fileEdit(_, let fe):          return try encoder.encode(fe)
        case .plan(_, let items):           return try encoder.encode(ACPPlanRowPayload(items: items))
        case .planDocument(_, let document): return try encoder.encode(ACPPlanRowPayload(document: document))
        case .systemNotice(_, let text):    return try encoder.encode(ACPSystemRowPayload(text: text))
        case .failureIncident(_, let incident): return try encoder.encode(ACPSystemRowPayload(failureIncident: incident))
        case .visualAid(let visual):        return try encoder.encode(visual)
        case .questionAnswer(let answer):   return try encoder.encode(ACPSystemRowPayload(questionAnswer: answer))
        case .outcomeCard(let card):        return try encoder.encode(ACPSystemRowPayload(outcomeCard: card))
        }
    }

    @MainActor
    public static func decode(kind: String, payload: Data) throws -> ACPMessage {
        switch kind {
        case "user":
            let p = try JSONDecoder().decode(UserPayload.self, from: payload)
            return .user(id: UUID(), messageId: p.messageId, text: p.text, attachments: ACPStoredFileChangeReport.attachments(p.attachments, restoring: p.fileChangeReport), delegatedSource: p.delegatedSource, pastedSpans: p.pastedSpans ?? [])
        case "agent":
            let p = try JSONDecoder().decode(TextPayload.self, from: payload)
            return .agent(id: UUID(), messageId: p.messageId, StreamingText(p.text, phase: ACPMessagePhase.codexPhase(in: p.metadata), metadata: p.metadata))
        case "thought":
            let p = try JSONDecoder().decode(TextPayload.self, from: payload)
            return .thought(id: UUID(), messageId: p.messageId, StreamingText(p.text, phase: ACPMessagePhase.codexPhase(in: p.metadata), metadata: p.metadata))
        case "tool_call":
            return .toolCall(try JSONDecoder().decode(ACPMessage.ToolCall.self, from: payload))
        case "file_edit":
            return .fileEdit(id: UUID(), try JSONDecoder().decode(ACPMessage.FileEdit.self, from: payload))
        case "plan":
            let p = try JSONDecoder().decode(ACPPlanRowPayload.self, from: payload)
            return p.document.map { .planDocument(id: UUID(), $0) } ?? .plan(id: UUID(), p.items)
        case "visual_aid":
            return .visualAid(try JSONDecoder().decode(ACPVisualAid.self, from: payload))
        case "system":
            let p = try JSONDecoder().decode(ACPSystemRowPayload.self, from: payload)
            if let answer = p.questionAnswer { return .questionAnswer(answer) }
            if let card = p.outcomeCard { return .outcomeCard(card) }
            return p.failureIncident.map { .failureIncident(id: UUID(), $0) } ?? .systemNotice(id: UUID(), text: p.text)
        default:
            return .systemNotice(id: UUID(), text: "(unknown message kind: \(kind))")
        }
    }

    public enum DisplayDecodingError: Error { case conflictingIdentity }

    /// Saved display carries its own stable identity; it never installs live state.
    @MainActor
    public static func decode(kind: String, payload: Data, identity: ACPMessage.StableIdentityKey) throws -> ACPMessage {
        let message = try decode(kind: kind, payload: payload)
        guard message.kind == kind else { throw DisplayDecodingError.conflictingIdentity }
        let restored: ACPMessage
        switch (message, identity) {
        case (.user(_, nil, let text, let attachments, let source, let spans), .userUUID(let id)):
            restored = .user(id: id, messageId: nil, text: text, attachments: attachments, delegatedSource: source, pastedSpans: spans)
        case (.agent(_, nil, let text), .agentUUID(let id)): restored = .agent(id: id, messageId: nil, text)
        case (.thought(_, nil, let text), .thoughtUUID(let id)): restored = .thought(id: id, messageId: nil, text)
        case (.fileEdit(_, let edit), .fileEdit(let id)): restored = .fileEdit(id: id, edit)
        case (.plan(_, let items), .plan(let id)): restored = .plan(id: id, items)
        case (.planDocument(_, let document), .plan(let id)): restored = .planDocument(id: id, document)
        case (.systemNotice(_, let text), .systemNotice(let id)): restored = .systemNotice(id: id, text: text)
        case (.failureIncident(_, let incident), .failureIncident(let id)): restored = .failureIncident(id: id, incident)
        default: restored = message
        }
        guard restored.stableIdentityKey == identity else { throw DisplayDecodingError.conflictingIdentity }
        return restored
    }

    private struct TextPayload: Codable {
        let messageId: String?
        let text: String
        let metadata: AnyCodable?

        init(messageId: String? = nil, text: String, metadata: AnyCodable? = nil) {
            self.messageId = messageId
            self.text = text
            self.metadata = metadata
        }
    }
    private struct UserPayload: Codable {
        let messageId: String?
        let text: String
        let attachments: [ACPMessage.Attachment]
        let delegatedSource: ACPDelegatedPromptSource?
        /// Absent for messages without pastes and for rows written before
        /// pasted-text badges existed; both decode as no spans.
        let pastedSpans: [ACPPastedTextSpan]?
        /// Absent for rows without a report reference.
        let fileChangeReport: ACPStoredFileChangeReport?

        init(messageId: String? = nil, text: String, attachments: [ACPMessage.Attachment], delegatedSource: ACPDelegatedPromptSource? = nil, pastedSpans: [ACPPastedTextSpan]? = nil, fileChangeReport: ACPStoredFileChangeReport? = nil) {
            self.messageId = messageId
            self.text = text
            self.attachments = attachments
            self.delegatedSource = delegatedSource
            self.pastedSpans = pastedSpans
            self.fileChangeReport = fileChangeReport
        }
    }
}

/// The `fileChangeReport` key of a stored user row. It sits beside
/// `attachments` because an older build sharing the store would draw anything
/// inside that array as a chip. Decoding never throws: a corrupt or future value
/// reads as no reference, and the row itself survives.
struct ACPStoredFileChangeReport: Codable {
    private struct Reference: Codable {
        let requestId: String
        let report: ACPAgentFileChangeReport?
    }

    private let reference: Reference?

    /// The row's report reference as an attachment, when the stored value was readable.
    var attachment: ACPMessage.Attachment? {
        reference.map { .fileChangeReportReference(requestId: $0.requestId, report: $0.report) }
    }

    /// A stored row's attachments. Only the sibling key can hold a reference:
    /// a report uri in `attachments` was planted, through a build without the
    /// agent filter, and must not win over it.
    static func attachments(
        _ stored: [ACPMessage.Attachment], restoring report: ACPStoredFileChangeReport?
    ) -> [ACPMessage.Attachment] {
        stored.filter { $0.fileChangeReportRequestId == nil } + (report?.attachment.map { [$0] } ?? [])
    }

    /// Nil when `attachments` holds no report reference.
    init?(attachments: [ACPMessage.Attachment]) {
        guard let attachment = attachments.first(where: { $0.fileChangeReportRequestId != nil }),
              let requestId = attachment.fileChangeReportRequestId
        else { return nil }
        reference = .init(requestId: requestId, report: attachment.fileChangeReport)
    }

    init(from decoder: Decoder) throws {
        guard let stored = try? Reference(from: decoder),
              ACPAgentFileChangeReport.isValidRequestId(stored.requestId),
              stored.report.map({ $0.requestId == stored.requestId }) ?? true
        else {
            reference = nil
            return
        }
        reference = stored
    }

    func encode(to encoder: Encoder) throws {
        try reference.encode(to: encoder)
    }
}
