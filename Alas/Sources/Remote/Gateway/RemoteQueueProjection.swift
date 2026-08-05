import Foundation

/// Pure translation between the in-process queue model and the remote wire
/// shape. Kept free of the gateway, the session, and SwiftUI so the mapping
/// can be unit-tested on its own — it is the single place that knows how a
/// `QueuedPrompt` becomes something a browser can render.
enum RemoteQueueProjection {
    static func project(_ items: [QueuedPrompt]) -> [RemoteQueuedPrompt] {
        items.map { item in
            var text = ""
            var imageCount = 0
            var resourceCount = 0
            for block in item.blocks {
                switch block {
                case .text(let value):
                    text += value
                case .image:
                    imageCount += 1
                case .resourceLink, .resource:
                    resourceCount += 1
                }
            }
            return RemoteQueuedPrompt(
                id: item.id.uuidString,
                text: text,
                imageCount: imageCount,
                resourceCount: resourceCount,
                status: item.status.rawValue,
                lastError: item.lastError)
        }
    }

    /// Queue-count badge value. Mirrors `ACPSession.visibleQueueCount`: an
    /// in-flight `.sending` head is rendered as its own bubble but is not
    /// part of the "still waiting" count.
    static func visibleCount(_ items: [RemoteQueuedPrompt]) -> Int {
        items.reduce(0) { $0 + ($1.status == "sending" ? 0 : 1) }
    }

    /// Flatten a restored composer draft into the plain text the web
    /// composer can hold. Mentions become their `@displayName` marker (the
    /// same form the submit path serializes them to); image segments are
    /// dropped, since the web client cannot re-stage bytes it never had.
    /// The queued bubble hides Edit when `imageCount > 0`, so dropping here
    /// is a defensive fallback rather than the expected path.
    static func plainText(from draft: ACPComposerDraft) -> String {
        var out = ""
        for segment in draft.segments {
            switch segment {
            case .text(let value):
                out += value
            case .mention(let displayName, _):
                out += "@\(displayName) "
            case .image:
                break
            }
        }
        return out
    }
}
