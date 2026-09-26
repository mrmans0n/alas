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

/// Render-side state the peer transcript keeps per row: the markdown parse
/// caches `ACPMarkdownText` memoizes into and the streaming buffers
/// `ACPThoughtView` observes. Buffers are synced from wire rows in an
/// `onChange` handler, never during body evaluation.
@MainActor
final class NativePeerRowCache {
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

    /// Grows a thought buffer in place while the forwarded text only gains a
    /// suffix (the streaming case) and swaps in a fresh buffer when it
    /// diverges, e.g. after a resubscribe replaced the row wholesale.
    func sync(_ messages: [RemoteWireMessage]) {
        for message in messages where message.kind == "thought" {
            let text = message.text ?? ""
            let buffer = thoughtBuffer(for: message.stableId)
            if text == buffer.value { continue }
            if text.hasPrefix(buffer.value) {
                buffer.append(String(text.dropFirst(buffer.value.count)))
            } else {
                thoughtBuffers[message.stableId] = StreamingText(text)
            }
        }
    }
}
