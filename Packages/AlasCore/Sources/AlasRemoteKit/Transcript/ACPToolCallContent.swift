import Foundation

public enum ACPContentBlock: Codable, Equatable, Sendable {
    case text(String)
    case resourceLink(uri: String, name: String?)
    case image(data: String?, uri: String?, mimeType: String?)
    case resource(uri: String, mimeType: String?, text: String)
    /// Wire-only: produced by `ACPSessionRunner.hydrate` just before a send, and
    /// by decoding what an agent sends. Never persist or render its bytes.
    case blobResource(uri: String, mimeType: String?, blob: String)

    private enum Keys: String, CodingKey { case type, text, uri, name, mimeType, data, resource }
    private struct EmbeddedResource: Codable, Equatable, Sendable {
        let uri: String
        let mimeType: String?
        let text: String?
        let blob: String?

        private enum CodingKeys: String, CodingKey {
            case uri, mimeType, text, blob
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(uri, forKey: .uri)
            try c.encodeIfPresent(mimeType, forKey: .mimeType)
            try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(blob, forKey: .blob)
        }

        public init(uri: String, mimeType: String?, text: String?, blob: String?) {
            self.uri = uri
            self.mimeType = mimeType
            self.text = text
            self.blob = blob
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "resource_link":
            self = .resourceLink(
                uri: try c.decode(String.self, forKey: .uri),
                name: try? c.decode(String.self, forKey: .name))
        case "image":
            self = .image(
                data: try? c.decode(String.self, forKey: .data),
                uri: try? c.decode(String.self, forKey: .uri),
                mimeType: try? c.decode(String.self, forKey: .mimeType))
        case "resource":
            let resource = try c.decode(EmbeddedResource.self, forKey: .resource)
            if let text = resource.text {
                self = .resource(uri: resource.uri, mimeType: resource.mimeType, text: text)
            } else if let blob = resource.blob {
                self = .blobResource(uri: resource.uri, mimeType: resource.mimeType, blob: blob)
            } else {
                self = .resourceLink(uri: resource.uri, name: URL(string: resource.uri)?.lastPathComponent)
            }
        default:
            self = .text("")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .resourceLink(let uri, let name):
            try c.encode("resource_link", forKey: .type)
            try c.encode(uri, forKey: .uri)
            try c.encodeIfPresent(name, forKey: .name)
        case .image(let data, let uri, let mime):
            try c.encode("image", forKey: .type)
            try c.encodeIfPresent(data, forKey: .data)
            try c.encodeIfPresent(uri, forKey: .uri)
            try c.encodeIfPresent(mime, forKey: .mimeType)
        case .resource(let uri, let mime, let text):
            try c.encode("resource", forKey: .type)
            try c.encode(
                EmbeddedResource(uri: uri, mimeType: mime, text: text, blob: nil),
                forKey: .resource)
        case .blobResource(let uri, let mime, let blob):
            try c.encode("resource", forKey: .type)
            try c.encode(
                EmbeddedResource(uri: uri, mimeType: mime, text: nil, blob: blob),
                forKey: .resource)
        }
    }
}

/// Per the ACP spec, a `tool_call.content` entry is a tagged union, not a
/// plain content block. The wrapper carries either a regular content
/// block, a file diff, or a terminal reference. Decoding the inner shape
/// directly (which our older code did) silently drops every real tool
/// result because they all arrive as `{"type": "content", ...}` and miss
/// `ACPContentBlock`'s text/resource_link/image discriminator.
public enum ACPToolCallContent: Codable, Equatable, Sendable {
    case content(ACPContentBlock)
    /// `kind`/`diffStats` come from the AIR diff-statistics extension
    /// (`_meta.kind` and `_meta.jetbrains.air.diffStats`) — claude-agent-acp
    /// ≥ 0.78 (#1122) and codex-acp ≥ 1.12 (#501). `diffStats` is nil when
    /// the adapter can't produce valid counts; callers fall back to
    /// computing their own.
    ///
    /// `patch` is the raw `_meta.diffPatch` payload of our adapter forks'
    /// exact-diff extension (see `ACPDiffPatch.swift`). It is kept as sent;
    /// `ACPToolCallDiff` validates it.
    case diff(
        path: String, oldText: String?, newText: String, kind: String?, diffStats: ACPDiffStats?,
        patch: ACPDiffPatchPayload? = nil)
    case terminal(terminalId: String)
    /// Forward-compatibility bucket so a future spec variant doesn't get
    /// misdecoded as empty text (the previous bug pattern).
    case unknown

    private enum Keys: String, CodingKey {
        case type, content, path, oldText, newText, terminalId
        case meta = "_meta"
    }

    /// Wire shape of `_meta` on a `diff` content block. See
    /// https://github.com/agentclientprotocol/codex-acp/blob/main/docs/diff-statistics-extension.md.
    private struct DiffMeta: Codable {
        let kind: String?
        let jetbrains: Jetbrains?
        let diffPatch: ACPDiffPatchPayload?
        struct Jetbrains: Codable { let air: Air? }
        struct Air: Codable { let diffStats: ACPDiffStats? }

        private enum CodingKeys: String, CodingKey {
            case kind, jetbrains, diffPatch
        }

        init(kind: String?, jetbrains: Jetbrains?, diffPatch: ACPDiffPatchPayload?) {
            self.kind = kind
            self.jetbrains = jetbrains
            self.diffPatch = diffPatch
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            // Each extension gets its own `try?`: a malformed one must not
            // drop `kind` or the other extension, let alone the block.
            jetbrains = (try? c.decodeIfPresent(Jetbrains.self, forKey: .jetbrains)) ?? nil
            diffPatch = (try? c.decodeIfPresent(ACPDiffPatchPayload.self, forKey: .diffPatch)) ?? nil
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(kind, forKey: .kind)
            try c.encodeIfPresent(jetbrains, forKey: .jetbrains)
            try c.encodeIfPresent(diffPatch, forKey: .diffPatch)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "content":
            self = .content(try c.decode(ACPContentBlock.self, forKey: .content))
        case "diff":
            let meta = (try? c.decodeIfPresent(DiffMeta.self, forKey: .meta)) ?? nil
            self = .diff(
                path: try c.decode(String.self, forKey: .path),
                oldText: try? c.decode(String.self, forKey: .oldText),
                newText: try c.decode(String.self, forKey: .newText),
                kind: meta?.kind,
                diffStats: meta?.jetbrains?.air?.diffStats,
                patch: meta?.diffPatch)
        case "terminal":
            self = .terminal(terminalId: try c.decode(String.self, forKey: .terminalId))
        case "text", "resource_link", "image", "resource":
            // Some adapters (and real permission-request payloads) send a
            // bare ACPContentBlock here instead of wrapping it in the
            // spec's tagged union. Decode it directly rather than losing it
            // to `.unknown` — that silently drops the block's text.
            self = .content(try ACPContentBlock(from: decoder))
        default:
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .content(let b):
            try c.encode("content", forKey: .type)
            try c.encode(b, forKey: .content)
        case .diff(let path, let old, let new, let kind, let diffStats, let patch):
            try c.encode("diff", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(old, forKey: .oldText)
            try c.encode(new, forKey: .newText)
            if kind != nil || diffStats != nil || patch != nil {
                let meta = DiffMeta(
                    kind: kind,
                    jetbrains: diffStats.map { DiffMeta.Jetbrains(air: DiffMeta.Air(diffStats: $0)) },
                    diffPatch: patch)
                try c.encode(meta, forKey: .meta)
            }
        case .terminal(let id):
            try c.encode("terminal", forKey: .type)
            try c.encode(id, forKey: .terminalId)
        case .unknown:
            // Unknown variants are receive-only forward-compat; they
            // never round-trip, so encoding them as a discriminator-only
            // object is acceptable.
            try c.encode("unknown", forKey: .type)
        }
    }

    /// This item with its patch payload marked as seen on a connection that
    /// did not negotiate `diffPatch`. Every other item is returned unchanged.
    public func markingDiffPatchUnnegotiated() -> ACPToolCallContent {
        guard case .diff(let path, let oldText, let newText, let kind, let diffStats, var patch?) = self else {
            return self
        }
        patch.negotiated = false
        return .diff(path: path, oldText: oldText, newText: newText, kind: kind, diffStats: diffStats, patch: patch)
    }
}

/// AIR "diff statistics" extension payload — `_meta.jetbrains.air.diffStats`
/// on a `diff` content block. All fields are required by the spec when
/// present at all; a payload missing either count fails to decode and the
/// whole `_meta` is dropped (the caller falls back to computing its own).
public struct ACPDiffStats: Codable, Equatable, Hashable, Sendable {
    public let added: Int
    public let removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }
}
