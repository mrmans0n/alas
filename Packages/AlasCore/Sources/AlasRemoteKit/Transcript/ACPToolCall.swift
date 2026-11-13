import Foundation

public struct ACPToolCallAsset: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case image
        case resource
    }

    public let kind: Kind
    public let data: String?
    public let uri: String?
    public let mimeType: String?
    public let name: String?

    public init(
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

    public static func image(
        data: String? = nil,
        uri: String? = nil,
        mimeType: String? = nil,
        name: String? = nil
    ) -> ACPToolCallAsset {
        .init(kind: .image, data: data, uri: uri, mimeType: mimeType, name: name)
    }

    public static func resource(
        uri: String,
        name: String?,
        mimeType: String? = nil
    ) -> ACPToolCallAsset {
        .init(kind: .resource, uri: uri, mimeType: mimeType, name: name)
    }
}

public struct ACPToolCall: Codable, Equatable, Hashable, Sendable {
    public let toolCallId: String
    public var title: String
    public var kind: String?
    public var status: String
    /// Stable, opaque tool identifier (ACP 1.22+) — e.g. `Bash`,
    /// `Read`, `exec_command` — distinct from `title` and `kind`.
    /// Presentation metadata only; grants no capability. Adapters that
    /// predate the field never send it, so this stays nil for them.
    public var name: String?
    /// Full text body of the tool call as the agent last reported it.
    /// Rendered inside the expanded card. Updated in place when the
    /// agent sends `tool_call_update` with new content.
    public var content: String
    /// In-memory revision for displayed content changes. Restored rows
    /// start from their persisted snapshot, so this is intentionally not
    /// encoded.
    public var contentRevision: Int = 0
    /// One-line teaser shown on the collapsed row (first text chunk,
    /// truncated). Computed at apply() time so we don't repeatedly
    /// scan the full content during rendering.
    public var preview: String?
    /// Supported explicit language label from a wrapping markdown fence
    /// that was removed from `content`.
    public var contentLanguage: String?
    /// Compact JSON/string form of the tool input reported by ACP. Kept so
    /// remote mirrors can show useful params even before output arrives.
    public var rawInput: String?
    /// Compact JSON/string form of the tool output reported by ACP.
    public var rawOutput: String?
    /// Structured metadata emitted by protocol payloads. Persisted for
    /// richer rendering and replay.
    public var metadata: AnyCodable?
    /// Preserved assets produced with the tool call.
    public var assets: [ACPToolCallAsset]
    public var locations: [String]
    /// Terminal IDs referenced by this call's structured content, in
    /// declaration order. The expanded card renders one
    /// `ACPTerminalTailView` per id, in addition to whatever text
    /// content the agent emitted.
    public var terminalIds: [String]
    /// Local observation times for the active part of a tool invocation.
    /// They are intentionally optional because an adapter can first report
    /// a call after it has already reached a terminal state.
    public var executionStartedAt: Date?
    public var executionFinishedAt: Date?
    /// Exact git patches from the `diffPatch` extension, validated, in
    /// block order. Empty for adapters that do not send them.
    public var diffs: [ACPToolCallDiff]

    public var executionDuration: TimeInterval? {
        guard let executionStartedAt, let executionFinishedAt else { return nil }
        return max(0, executionFinishedAt.timeIntervalSince(executionStartedAt))
    }

    /// `name`, treating a blank string the same as absent. Adapters
    /// that predate the field, or send an empty string, should fall
    /// back to the existing kind/title heuristics exactly as before.
    public var nonEmptyName: String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }

    /// Set when `content` has been truncated to save memory. The full
    /// content is still in SQLite (`ACPSessionStore.loadMessages`) and
    /// can be refetched on demand for an expanded card.
    public var isContentTruncated: Bool = false

    /// How many characters of `content` we keep in memory for an
    /// off-window completed tool call. Tuned to fit the collapsed-card
    /// teaser + a small head of context — the rest is paged in if the
    /// user expands.
    public static let truncatedTailBytes: Int = 4096

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
    public var appliedRawContent: String? = nil
    /// In-memory-only count of `ACPToolCallContent` items already
    /// processed for asset/terminal-id extraction. Pairs with
    /// `appliedRawContent`: when the next update's flattened content
    /// has the previous as a prefix, items 0..<appliedItemCount are
    /// already accounted for and only the tail is scanned.
    public var appliedItemCount: Int = 0
    /// In-memory-only record of the `isFinal` value used the last time
    /// `appliedRawContent` was computed. The trailing-fence strip step
    /// in `stripWrappingFence` depends on `isFinal`, so when an update
    /// arrives with identical content but a different `isFinal` (e.g.
    /// the snapshot flips to `completed` without the body changing)
    /// we must re-strip the tail; otherwise the identical-content fast
    /// path can skip everything.
    public var appliedIsFinal: Bool = false
    /// In-memory-only cache of the last stripped-raw content (after
    /// the opening fence line was removed, before the trailing-fence
    /// strip). The next suffix-only update appends to THIS, not to
    /// `tc.content` (which may have a trailing fence stripped if the
    /// last apply was `isFinal`). Without it, the opening fence's
    /// separator newline would be double-counted when the fence line
    /// arrived alone (e.g. `"```swift"` then `"\nlet x = 1"`).
    public var appliedStrippedRaw: String = ""
    /// In-memory-only flag: the opening fence line was seen but had
    /// no trailing newline yet (the first chunk was a partial fence
    /// line like `"```swift"`). The next suffix's first newline
    /// terminates the fence line and starts the stripped-raw body;
    /// until then `appliedStrippedRaw` stays empty.
    public var appliedOpeningFenceUnterminated: Bool = false
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
    public var appliedItemsSnapshot: [ACPToolCallContent] = []
    /// In-memory-only flag: whether `stripWrappingFence` actually
    /// stripped an opening fence line from `appliedRawContent`. The
    /// trailing-fence strip in `stripTrailingFenceLine` must only
    /// run when an opening fence was recognized — ordinary tool
    /// output whose final line happens to be `` ``` `` must NOT be
    /// dropped. Mirrors `stripWrappingFence`'s `isOpeningFence`
    /// guard.
    public var appliedOpeningFenceStripped: Bool = false

    /// Replace `content` with its first `truncatedTailBytes` characters
    /// and mark the message as truncated. No-op if already truncated.
    public mutating func truncateForOffWindow() {
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

    public init(toolCallId: String, title: String, kind: String? = nil,
         status: String, content: String? = nil, preview: String? = nil,
         contentLanguage: String? = nil, rawInput: String? = nil,
         rawOutput: String? = nil, metadata: AnyCodable? = nil,
         assets: [ACPToolCallAsset] = [],
         locations: [String]? = nil, terminalIds: [String] = [],
         executionStartedAt: Date? = nil, executionFinishedAt: Date? = nil,
         name: String? = nil, diffs: [ACPToolCallDiff] = [])
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
        self.executionStartedAt = executionStartedAt
        self.executionFinishedAt = executionFinishedAt
        self.name = name
        self.diffs = diffs
    }

    // Backwards-compatible decoder: older messages persisted only a
    // `contentSummary` field. We still read it so the previous
    // session history doesn't go blank after upgrade.
    public enum CodingKeys: String, CodingKey, Sendable {
        case toolCallId, title, kind, status, content, preview,
             contentSummary, contentLanguage, rawInput, rawOutput, metadata,
             assets, locations, terminalIds, executionStartedAt, executionFinishedAt,
             name, diffs
    }
    public init(from decoder: Decoder) throws {
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
        assets = (try? c.decode([ACPToolCallAsset].self, forKey: .assets)) ?? []
        locations = (try? c.decode([String].self, forKey: .locations)) ?? []
        terminalIds = (try? c.decode([String].self, forKey: .terminalIds)) ?? []
        executionStartedAt = try? c.decode(Date.self, forKey: .executionStartedAt)
        executionFinishedAt = try? c.decode(Date.self, forKey: .executionFinishedAt)
        name = try? c.decode(String.self, forKey: .name)
        diffs = Self.decodeDiffs(c)
    }

    /// Element by element. A diff with a failure or source this build
    /// does not know (say, from a newer peer) is kept as an invalid diff
    /// for its path, so the row shows "Change unavailable" instead of
    /// losing the file; an unknown source counts as a proposal, so it is
    /// never labelled written. An entry without a path is skipped.
    private static func decodeDiffs(_ c: KeyedDecodingContainer<CodingKeys>) -> [ACPToolCallDiff] {
        guard var items = try? c.nestedUnkeyedContainer(forKey: .diffs) else { return [] }
        struct Unreadable: Decodable {
            let path: String?
            let source: String?
            init(from decoder: Decoder) {
                enum Keys: String, CodingKey { case path, source }
                let c = try? decoder.container(keyedBy: Keys.self)
                path = try? c?.decodeIfPresent(String.self, forKey: .path)
                source = try? c?.decodeIfPresent(String.self, forKey: .source)
            }
        }
        var diffs: [ACPToolCallDiff] = []
        while !items.isAtEnd {
            if let diff = try? items.decode(ACPToolCallDiff.self) {
                diffs.append(diff)
            } else if let unreadable = try? items.decode(Unreadable.self) {
                guard let path = unreadable.path else { continue }
                diffs.append(ACPToolCallDiff(
                    path: path,
                    source: unreadable.source.flatMap(ACPToolCallDiff.Source.init(rawValue:)) ?? .permissionRequest,
                    patch: nil, failure: .malformedHunk, change: nil, added: 0, removed: 0))
            } else {
                break
            }
        }
        return diffs
    }
    public func encode(to encoder: Encoder) throws {
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
        try c.encodeIfPresent(executionStartedAt, forKey: .executionStartedAt)
        try c.encodeIfPresent(executionFinishedAt, forKey: .executionFinishedAt)
        try c.encodeIfPresent(name, forKey: .name)
        if !diffs.isEmpty {
            try c.encode(diffs, forKey: .diffs)
        }
    }

    // Manual Equatable/Hashable: `isContentTruncated` is an in-memory-only
    // flag that flips when off-window content is truncated. Two tool calls
    // representing the same logical row must remain equal across that
    // boundary, so we exclude the flag from both conformances.
    public static func == (lhs: Self, rhs: Self) -> Bool {
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
            && lhs.executionStartedAt == rhs.executionStartedAt
            && lhs.executionFinishedAt == rhs.executionFinishedAt
            && lhs.name == rhs.name
            && lhs.diffs == rhs.diffs
    }

    public func hash(into hasher: inout Hasher) {
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
        hasher.combine(executionStartedAt)
        hasher.combine(executionFinishedAt)
        hasher.combine(name)
        hasher.combine(diffs)
    }

    public mutating func replaceContent(_ newContent: String) {
        guard content != newContent else { return }
        content = newContent
        contentRevision &+= 1
    }
}
