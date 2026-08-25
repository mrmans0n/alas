import Foundation

enum ACPMessage: Equatable {
    case user(id: UUID, messageId: String?, text: String, attachments: [Attachment], delegatedSource: ACPDelegatedPromptSource? = nil)
    case agent(id: UUID, messageId: String?, StreamingText)
    case thought(id: UUID, messageId: String?, StreamingText)
    case toolCall(ToolCall)
    case fileEdit(id: UUID, FileEdit)
    case plan(id: UUID, [PlanItem])
    case systemNotice(id: UUID, text: String)

    static func user(id: UUID, text: String, attachments: [Attachment]) -> ACPMessage {
        .user(id: id, messageId: nil, text: text, attachments: attachments)
    }

    static func agent(id: UUID, _ text: StreamingText) -> ACPMessage {
        .agent(id: id, messageId: nil, text)
    }

    static func thought(id: UUID, _ text: StreamingText) -> ACPMessage {
        .thought(id: id, messageId: nil, text)
    }

    enum StableIdentityKey: Hashable {
        case userMessageId(String)
        case agentMessageId(String)
        case thoughtMessageId(String)
        case userUUID(UUID)
        case agentUUID(UUID)
        case thoughtUUID(UUID)
        case fileEdit(UUID)
        case plan(UUID)
        case systemNotice(UUID)
        case toolCall(String)
    }

    var stableIdentityKey: StableIdentityKey {
        switch self {
        case .user(let id, let messageId, _, _, _):
            messageId.map(StableIdentityKey.userMessageId) ?? .userUUID(id)
        case .agent(let id, let messageId, _):
            messageId.map(StableIdentityKey.agentMessageId) ?? .agentUUID(id)
        case .thought(let id, let messageId, _):
            messageId.map(StableIdentityKey.thoughtMessageId) ?? .thoughtUUID(id)
        case .fileEdit(let id, _):
            .fileEdit(id)
        case .plan(let id, _):
            .plan(id)
        case .systemNotice(let id, _):
            .systemNotice(id)
        case .toolCall(let tc):
            .toolCall(tc.toolCallId)
        }
    }

    var stableId: String {
        Self.stableId(for: stableIdentityKey)
    }

    static func stableId(for key: StableIdentityKey) -> String {
        switch key {
        case .userMessageId(let messageId):
            "acp-user:\(messageId)"
        case .agentMessageId(let messageId):
            "acp-agent:\(messageId)"
        case .thoughtMessageId(let messageId):
            "acp-thought:\(messageId)"
        case .userUUID(let id), .agentUUID(let id), .thoughtUUID(let id),
             .fileEdit(let id), .plan(let id), .systemNotice(let id):
            id.uuidString
        case .toolCall(let toolCallId):
            "tc-\(toolCallId)"
        }
    }

    @MainActor
    var contentUTF8Length: Int {
        switch self {
        case .user(_, _, let text, _, _):
            text.utf8.count
        case .agent(_, _, let text), .thought(_, _, let text):
            text.utf8Length
        case .systemNotice(_, let text):
            text.utf8.count
        case .toolCall(let tc):
            tc.content.utf8.count
        case .fileEdit, .plan:
            0
        }
    }

    var kind: String {
        switch self {
        case .user: "user"
        case .agent: "agent"
        case .thought: "thought"
        case .toolCall: "tool_call"
        case .fileEdit: "file_edit"
        case .plan: "plan"
        case .systemNotice: "system"
        }
    }

    struct Attachment: Codable, Equatable, Hashable, Sendable {
        let uri: String
        let name: String?
        /// Image MIME type (e.g. `image/png`) when this attachment is an
        /// image; `nil` for mention/resource-link attachments. Drives
        /// thumbnail rendering in the user bubble. Synthesized Codable
        /// decodes a missing key as nil, so legacy rows stay valid.
        let mimeType: String?

        init(uri: String, name: String?, mimeType: String? = nil) {
            self.uri = uri
            self.name = name
            self.mimeType = mimeType
        }
    }

    struct ToolCallAsset: Codable, Equatable, Hashable, Sendable {
        enum Kind: String, Codable, Equatable, Hashable, Sendable {
            case image
            case resource
        }

        let kind: Kind
        let data: String?
        let uri: String?
        let mimeType: String?
        let name: String?

        init(
            kind: Kind,
            data: String? = nil,
            uri: String? = nil,
            mimeType: String? = nil,
            name: String? = nil
        ) {
            self.kind = kind
            self.data = data
            self.uri = uri
            self.mimeType = mimeType
            self.name = name
        }

        static func image(
            data: String? = nil,
            uri: String? = nil,
            mimeType: String? = nil,
            name: String? = nil
        ) -> ToolCallAsset {
            .init(kind: .image, data: data, uri: uri, mimeType: mimeType, name: name)
        }

        static func resource(
            uri: String,
            name: String?,
            mimeType: String? = nil
        ) -> ToolCallAsset {
            .init(kind: .resource, uri: uri, mimeType: mimeType, name: name)
        }
    }

    struct ToolCall: Codable, Equatable, Hashable, Sendable {
        let toolCallId: String
        var title: String
        var kind: String?
        var status: String
        /// Full text body of the tool call as the agent last reported it.
        /// Rendered inside the expanded card. Updated in place when the
        /// agent sends `tool_call_update` with new content.
        var content: String
        /// In-memory revision for displayed content changes. Restored rows
        /// start from their persisted snapshot, so this is intentionally not
        /// encoded.
        var contentRevision: Int = 0
        /// One-line teaser shown on the collapsed row (first text chunk,
        /// truncated). Computed at apply() time so we don't repeatedly
        /// scan the full content during rendering.
        var preview: String?
        /// Supported explicit language label from a wrapping markdown fence
        /// that was removed from `content`.
        var contentLanguage: String?
        /// Compact JSON/string form of the tool input reported by ACP. Kept so
        /// remote mirrors can show useful params even before output arrives.
        var rawInput: String?
        /// Compact JSON/string form of the tool output reported by ACP.
        var rawOutput: String?
        /// Structured metadata emitted by protocol payloads. Persisted for
        /// richer rendering and replay.
        var metadata: AnyCodable?
        /// Preserved assets produced with the tool call.
        var assets: [ToolCallAsset]
        var locations: [String]
        /// Terminal IDs referenced by this call's structured content, in
        /// declaration order. The expanded card renders one
        /// `ACPTerminalTailView` per id, in addition to whatever text
        /// content the agent emitted.
        var terminalIds: [String]

        /// Set when `content` has been truncated to save memory. The full
        /// content is still in SQLite (`ACPSessionStore.loadMessages`) and
        /// can be refetched on demand for an expanded card.
        var isContentTruncated: Bool = false

        /// How many characters of `content` we keep in memory for an
        /// off-window completed tool call. Tuned to fit the collapsed-card
        /// teaser + a small head of context — the rest is paged in if the
        /// user expands.
        static let truncatedTailBytes: Int = 4096

        /// In-memory-only cache of the last fully-applied flattened raw
        /// content (before fence stripping), used by
        /// `applyToolCallUpdateFields`/`applyToolCallPayloadFields` to
        /// detect prefix-extension updates and process only the appended
        /// suffix. Adapters that stream tool output re-emit the full
        /// cumulative content on every `tool_call_update`, so without
        /// this cache each update re-runs `stripWrappingFence`,
        /// `previewLine`, `extractAssets`, and `extractTerminalIds` over
        /// the whole growing body — O(m·k) total work for m bytes across k
        /// updates. Never encoded: restored rows start with a nil cache
        /// and take the full-reprocess path once, which is fine.
        var appliedRawContent: String? = nil
        /// In-memory-only count of `ACPToolCallContent` items already
        /// processed for asset/terminal-id extraction. Pairs with
        /// `appliedRawContent`: when the next update's flattened content
        /// has the previous as a prefix, items 0..<appliedItemCount are
        /// already accounted for and only the tail is scanned.
        var appliedItemCount: Int = 0
        /// In-memory-only record of the `isFinal` value used the last time
        /// `appliedRawContent` was computed. The trailing-fence strip step
        /// in `stripWrappingFence` depends on `isFinal`, so when an update
        /// arrives with identical content but a different `isFinal` (e.g.
        /// the snapshot flips to `completed` without the body changing)
        /// we must re-strip the tail; otherwise the identical-content fast
        /// path can skip everything.
        var appliedIsFinal: Bool = false
        /// In-memory-only cache of the last stripped-raw content (after
        /// the opening fence line was removed, before the trailing-fence
        /// strip). The next suffix-only update appends to THIS, not to
        /// `tc.content` (which may have a trailing fence stripped if the
        /// last apply was `isFinal`). Without it, the opening fence's
        /// separator newline would be double-counted when the fence line
        /// arrived alone (e.g. `"```swift"` then `"\nlet x = 1"`).
        var appliedStrippedRaw: String = ""
        /// In-memory-only flag: the opening fence line was seen but had
        /// no trailing newline yet (the first chunk was a partial fence
        /// line like `"```swift"`). The next suffix's first newline
        /// terminates the fence line and starts the stripped-raw body;
        /// until then `appliedStrippedRaw` stays empty.
        var appliedOpeningFenceUnterminated: Bool = false
        /// In-memory-only cache of the previous content items array, used
        /// to verify that the first `appliedItemCount` items' STRUCTURED
        /// content (images, resource-links, terminals, diffs) is unchanged
        /// before taking the suffix-only fast path. `flatten` ignores
        /// those item kinds, so equal flattened text does NOT imply the
        /// structured items are the same — an in-place replacement (e.g.
        /// `[text, image(old)]` -> `[text, image(new)]`) would otherwise
        /// skip `extractAssets`/`extractTerminalIds`. Only structured
        /// items are compared; text items are allowed to grow in place
        /// (the common cumulative shape `[text("a")]` -> `[text("ab")]`)
        /// so the suffix path still fires. COW keeps storage cheap.
        var appliedItemsSnapshot: [ACPToolCallContent] = []
        /// In-memory-only flag: whether `stripWrappingFence` actually
        /// stripped an opening fence line from `appliedRawContent`. The
        /// trailing-fence strip in `stripTrailingFenceLine` must only
        /// run when an opening fence was recognized — ordinary tool
        /// output whose final line happens to be `` ``` `` must NOT be
        /// dropped. Mirrors `stripWrappingFence`'s `isOpeningFence`
        /// guard.
        var appliedOpeningFenceStripped: Bool = false

        /// Replace `content` with its first `truncatedTailBytes` characters
        /// and mark the message as truncated. No-op if already truncated.
        mutating func truncateForOffWindow() {
            guard !isContentTruncated else { return }
            if content.count > Self.truncatedTailBytes {
                content = String(content.prefix(Self.truncatedTailBytes))
                contentRevision &+= 1
            }
            isContentTruncated = true
            // The in-memory content no longer matches `appliedRawContent`,
            // so the next update can't take the suffix-only path: drop the
            // cache and let it reprocess fully (restoring the complete body).
            appliedRawContent = nil
            appliedItemCount = 0
            appliedIsFinal = false
            appliedStrippedRaw = ""
            appliedOpeningFenceUnterminated = false
            appliedItemsSnapshot = []
            appliedOpeningFenceStripped = false
        }

        init(toolCallId: String, title: String, kind: String? = nil,
             status: String, content: String? = nil, preview: String? = nil,
             contentLanguage: String? = nil, rawInput: String? = nil,
             rawOutput: String? = nil, metadata: AnyCodable? = nil,
             assets: [ToolCallAsset] = [],
             locations: [String]? = nil, terminalIds: [String] = [])
        {
            self.toolCallId = toolCallId
            self.title = title
            self.kind = kind
            self.status = status
            self.content = content ?? ""
            self.preview = preview
            self.contentLanguage = contentLanguage
            self.rawInput = rawInput
            self.rawOutput = rawOutput
            self.metadata = metadata
            self.assets = assets
            self.locations = locations ?? []
            self.terminalIds = terminalIds
        }

        // Backwards-compatible decoder: older messages persisted only a
        // `contentSummary` field. We still read it so the previous
        // session history doesn't go blank after upgrade.
        enum CodingKeys: String, CodingKey {
            case toolCallId, title, kind, status, content, preview,
                 contentSummary, contentLanguage, rawInput, rawOutput, metadata,
                 assets, locations, terminalIds
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            toolCallId = try c.decode(String.self, forKey: .toolCallId)
            title = try c.decode(String.self, forKey: .title)
            kind = try? c.decode(String.self, forKey: .kind)
            status = try c.decode(String.self, forKey: .status)
            content = (try? c.decode(String.self, forKey: .content)) ?? ""
            preview = (try? c.decode(String.self, forKey: .preview))
                ?? (try? c.decode(String.self, forKey: .contentSummary))
            contentLanguage = try? c.decode(String.self, forKey: .contentLanguage)
            rawInput = try? c.decode(String.self, forKey: .rawInput)
            rawOutput = try? c.decode(String.self, forKey: .rawOutput)
            metadata = try? c.decode(AnyCodable.self, forKey: .metadata)
            assets = (try? c.decode([ToolCallAsset].self, forKey: .assets)) ?? []
            locations = (try? c.decode([String].self, forKey: .locations)) ?? []
            terminalIds = (try? c.decode([String].self, forKey: .terminalIds)) ?? []
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(toolCallId, forKey: .toolCallId)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(kind, forKey: .kind)
            try c.encode(status, forKey: .status)
            try c.encode(content, forKey: .content)
            try c.encodeIfPresent(preview, forKey: .preview)
            try c.encodeIfPresent(contentLanguage, forKey: .contentLanguage)
            try c.encodeIfPresent(rawInput, forKey: .rawInput)
            try c.encodeIfPresent(rawOutput, forKey: .rawOutput)
            try c.encodeIfPresent(metadata, forKey: .metadata)
            try c.encode(assets, forKey: .assets)
            try c.encode(locations, forKey: .locations)
            try c.encode(terminalIds, forKey: .terminalIds)
        }

        // Manual Equatable/Hashable: `isContentTruncated` is an in-memory-only
        // flag that flips when off-window content is truncated. Two tool calls
        // representing the same logical row must remain equal across that
        // boundary, so we exclude the flag from both conformances.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.toolCallId == rhs.toolCallId
                && lhs.title == rhs.title
                && lhs.kind == rhs.kind
                && lhs.status == rhs.status
                && lhs.content == rhs.content
                && lhs.preview == rhs.preview
                && lhs.contentLanguage == rhs.contentLanguage
                && lhs.rawInput == rhs.rawInput
                && lhs.rawOutput == rhs.rawOutput
                && lhs.metadata == rhs.metadata
                && lhs.assets == rhs.assets
                && lhs.locations == rhs.locations
                && lhs.terminalIds == rhs.terminalIds
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(toolCallId)
            hasher.combine(title)
            hasher.combine(kind)
            hasher.combine(status)
            hasher.combine(content)
            hasher.combine(preview)
            hasher.combine(contentLanguage)
            hasher.combine(rawInput)
            hasher.combine(rawOutput)
            hasher.combine(metadata)
            hasher.combine(assets)
            hasher.combine(locations)
            hasher.combine(terminalIds)
        }

        mutating func replaceContent(_ newContent: String) {
            guard content != newContent else { return }
            content = newContent
            contentRevision &+= 1
        }
    }

    struct FileEdit: Codable, Equatable, Hashable, Sendable {
        let path: String
        var added: Int
        var removed: Int
        var oldText: String?
        var newText: String

        init(path: String, added: Int, removed: Int, oldText: String? = nil, newText: String = "") {
            self.path = path
            self.added = added
            self.removed = removed
            self.oldText = oldText
            self.newText = newText
        }

        private enum CodingKeys: String, CodingKey {
            case path, added, removed, oldText, newText
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            added = try c.decode(Int.self, forKey: .added)
            removed = try c.decode(Int.self, forKey: .removed)
            oldText = try c.decodeIfPresent(String.self, forKey: .oldText)
            newText = try c.decodeIfPresent(String.self, forKey: .newText) ?? ""
        }
    }

    struct PlanItem: Codable, Equatable, Hashable, Sendable {
        let content: String
        var status: String   // "pending" | "in_progress" | "completed"
    }
}

/// The documented, versioned context-compaction facts carried on a synthetic
/// tool call. Unknown metadata is intentionally not projected into the UI.
struct ACPContextCompaction: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case inProgress
        case completed
        case failed
        case cancelled
        case other(String)
    }

    let id: String
    let status: Status
    let trigger: String?
    let tokensBefore: Int?
    let tokensAfter: Int?
    let durationMs: Int?
    let error: String?

    init?(toolCall: ACPMessage.ToolCall) {
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

enum ACPMessageCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    @MainActor
    static func encode(_ m: ACPMessage) throws -> Data {
        switch m {
        case .user(_, let messageId, let text, let atts, let delegatedSource): return try encoder.encode(UserPayload(messageId: messageId, text: text, attachments: atts, delegatedSource: delegatedSource))
        case .agent(_, let messageId, let buf):            return try encoder.encode(TextPayload(messageId: messageId, text: buf.value, metadata: buf.metadata))
        case .thought(_, let messageId, let buf):          return try encoder.encode(TextPayload(messageId: messageId, text: buf.value, metadata: buf.metadata))
        case .toolCall(let tc):             return try encoder.encode(tc)
        case .fileEdit(_, let fe):          return try encoder.encode(fe)
        case .plan(_, let items):           return try encoder.encode(PlanPayload(items: items))
        case .systemNotice(_, let text):    return try encoder.encode(TextPayload(text: text))
        }
    }

    @MainActor
    static func decode(kind: String, payload: Data) throws -> ACPMessage {
        switch kind {
        case "user":
            let p = try JSONDecoder().decode(UserPayload.self, from: payload)
            return .user(id: UUID(), messageId: p.messageId, text: p.text, attachments: p.attachments, delegatedSource: p.delegatedSource)
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
            return .plan(id: UUID(), try JSONDecoder().decode(PlanPayload.self, from: payload).items)
        case "system":
            return .systemNotice(id: UUID(), text: try JSONDecoder().decode(TextPayload.self, from: payload).text)
        default:
            return .systemNotice(id: UUID(), text: "(unknown message kind: \(kind))")
        }
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

        init(messageId: String? = nil, text: String, attachments: [ACPMessage.Attachment], delegatedSource: ACPDelegatedPromptSource? = nil) {
            self.messageId = messageId
            self.text = text
            self.attachments = attachments
            self.delegatedSource = delegatedSource
        }
    }
    private struct PlanPayload: Codable { let items: [ACPMessage.PlanItem] }
}
