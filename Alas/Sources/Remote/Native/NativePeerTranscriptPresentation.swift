import Foundation

/// One forwarded transcript row, decoded into the value types the local ACP
/// transcript renders so the peer pane can reuse its cards instead of showing
/// flattened text.
enum NativePeerRow: Equatable {
    case user(String)
    case agent(String)
    case thought(String)
    case toolCall(ACPMessage.ToolCall)
    case fileEdit(ACPMessage.FileEdit)
    case plan([ACPMessage.PlanItem])
    case systemNotice(String)

    init(message: RemoteWireMessage) {
        let text = message.text ?? ""
        switch message.kind {
        case "user":
            self = .user(text)
        case "agent":
            self = .agent(text)
        case "thought":
            self = .thought(text)
        case "systemNotice":
            self = .systemNotice(text)
        case "toolCall":
            if let call: ACPMessage.ToolCall = Self.decode(message.json) {
                self = .toolCall(call)
            } else {
                self = .systemNotice("Tool call details are unavailable.")
            }
        case "fileEdit":
            if let edit: ACPMessage.FileEdit = Self.decode(message.json) {
                self = .fileEdit(edit)
            } else {
                self = .systemNotice("File edit details are unavailable.")
            }
        case "plan":
            if let items: [ACPMessage.PlanItem] = Self.decode(message.json) {
                self = .plan(items)
            } else {
                self = .systemNotice("Plan details are unavailable.")
            }
        default:
            self = .systemNotice(text)
        }
    }

    private static func decode<T: Decodable>(_ json: String?) -> T? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}

/// Render-side state the peer transcript keeps per row: the decoded row
/// (so JSON payloads decode once per change, not once per render), the
/// markdown parse caches `ACPMarkdownText` memoizes into, and the streaming
/// buffers `ACPThoughtView` observes. Synced from wire rows outside view
/// body evaluation.
@MainActor
final class NativePeerRowCache {
    private struct Decoded {
        let source: RemoteWireMessage
        let row: NativePeerRow
        let proxy: ACPMessage
    }

    private var decoded: [String: Decoded] = [:]
    private var markdownCaches: [String: ACPMarkdownBlockCache] = [:]
    private var thoughtBuffers: [String: StreamingText] = [:]

    func markdownCache(for stableId: String) -> ACPMarkdownBlockCache {
        if let cache = markdownCaches[stableId] { return cache }
        let cache = ACPMarkdownBlockCache()
        markdownCaches[stableId] = cache
        return cache
    }

    /// `seed` only matters for the first request, so a row that mounts before
    /// the next `sync` still renders its current text.
    func thoughtBuffer(for stableId: String, seed: String = "") -> StreamingText {
        if let buffer = thoughtBuffers[stableId] { return buffer }
        let buffer = StreamingText(seed)
        thoughtBuffers[stableId] = buffer
        return buffer
    }

    func row(for message: RemoteWireMessage) -> NativePeerRow {
        entry(for: message).row
    }

    /// The local message each row stands for, in the same order, so the
    /// local transcript's activity fold can run over peer rows.
    func proxies(for messages: [RemoteWireMessage]) -> [ACPMessage] {
        messages.map { entry(for: $0).proxy }
    }

    /// Grows a thought buffer in place while the forwarded text only gains a
    /// suffix (the streaming case) and replaces its contents when it
    /// diverges, e.g. after a resubscribe rewrote the row. The buffer object
    /// never changes, so a mounted `ACPThoughtView` observing it is notified
    /// either way.
    func sync(_ messages: [RemoteWireMessage]) {
        for message in messages where message.kind == "thought" {
            let text = message.text ?? ""
            let buffer = thoughtBuffer(for: message.stableId)
            if text == buffer.value { continue }
            if text.hasPrefix(buffer.value) {
                buffer.append(String(text.dropFirst(buffer.value.count)))
            } else {
                buffer.replace(with: text)
            }
        }
    }

    private func entry(for message: RemoteWireMessage) -> Decoded {
        if let cached = decoded[message.stableId], cached.source == message { return cached }
        let row = NativePeerRow(message: message)
        let entry = Decoded(source: message, row: row, proxy: proxy(for: row, stableId: message.stableId))
        decoded[message.stableId] = entry
        return entry
    }

    private func proxy(for row: NativePeerRow, stableId: String) -> ACPMessage {
        switch row {
        case .user(let text):
            .user(id: UUID(), messageId: nil, text: text, attachments: [])
        case .agent(let text):
            .agent(id: UUID(), messageId: nil, StreamingText(text))
        case .thought(let text):
            .thought(id: UUID(), messageId: nil, thoughtBuffer(for: stableId, seed: text))
        case .toolCall(let call):
            .toolCall(call)
        case .fileEdit(let edit):
            .fileEdit(id: UUID(), edit)
        case .plan(let items):
            .plan(id: UUID(), items)
        case .systemNotice(let text):
            .systemNotice(id: UUID(), text: text)
        }
    }
}

/// Folds a peer transcript's thinking and tool calls into the same
/// activity and completed-work disclosures the local transcript shows.
enum NativePeerTranscriptFold {
    /// `proxies` must line up with `messages`. Row indices are positions in
    /// that local array, not the wire `index`: a paged transcript starts
    /// mid-history, and the fold indexes `proxies` directly.
    @MainActor
    static func renderRows(
        messages: [RemoteWireMessage],
        proxies: [ACPMessage],
        isTurnActive: Bool,
        enabled: Bool,
        isExpanded: (ACPTranscriptToolCallGroup) -> Bool = { _ in false },
        memberLimit: (ACPTranscriptToolCallGroup) -> Int? = { _ in nil }
    ) -> [ACPTranscriptRenderRow] {
        let rows = messages.enumerated().map {
            ACPTranscriptVisibleRow(index: $0.offset, stableId: $0.element.stableId)
        }
        let latestUserIndex = proxies.lastIndex {
            if case .user = $0 { return true }
            return false
        }
        let options = ACPToolCallGrouping.Options(
            enabled: enabled,
            currentTurnAnswerIndex: ACPToolCallGrouping.currentTurnAnswerIndex(
                messages: proxies,
                currentTurnUserIndex: latestUserIndex,
                isTurnActive: isTurnActive
            ),
            isTurnActive: isTurnActive
        )
        return ACPToolCallGrouping.fold(
            rows: rows, messages: proxies, options: options,
            isExpanded: isExpanded, memberLimit: memberLimit
        )
    }
}
