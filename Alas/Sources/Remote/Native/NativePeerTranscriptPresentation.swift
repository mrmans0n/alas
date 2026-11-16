import Foundation

/// The shared row decoder lives in AlasRemoteKit.
typealias NativePeerRow = RemoteTranscriptRow

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
        let foldItem: ACPTranscriptFoldItem
    }

    private let decodeRow: (RemoteWireMessage) -> NativePeerRow

    init(decodeRow: @escaping (RemoteWireMessage) -> NativePeerRow = NativePeerRow.init(message:)) {
        self.decodeRow = decodeRow
    }

    func removeAll() {
        decoded.removeAll()
        markdownCaches.removeAll()
        thoughtBuffers.removeAll()
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

    /// Each row's fold facts, in the same order, decoded once per change.
    func foldItems(for messages: [RemoteWireMessage]) -> [ACPTranscriptFoldItem] {
        messages.map { entry(for: $0).foldItem }
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
        let row = decodeRow(message)
        let entry = Decoded(
            source: message, row: row, foldItem: RemoteTranscriptFold.item(for: message)
        )
        decoded[message.stableId] = entry
        return entry
    }
}

/// Folds a peer transcript's thinking and tool calls into the same
/// activity and completed-work disclosures the local transcript shows.
enum NativePeerTranscriptFold {
    /// Row indices are positions in `messages`, not the wire `index`: a
    /// paged transcript starts mid-history.
    static func renderRows(
        messages: [RemoteWireMessage],
        items: [ACPTranscriptFoldItem],
        isTurnActive: Bool,
        enabled: Bool,
        isExpanded: (ACPTranscriptToolCallGroup) -> Bool = { _ in false },
        memberLimit: (ACPTranscriptToolCallGroup) -> Int? = { _ in nil }
    ) -> [ACPTranscriptRenderRow] {
        guard enabled else {
            return messages.enumerated().map { .message(.init(index: $0.offset, stableId: $0.element.stableId)) }
        }
        return RemoteTranscriptFold.renderRows(
            messages: messages, items: items, isTurnActive: isTurnActive, isExpanded: isExpanded, memberLimit: memberLimit
        )
    }
}
