import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasSessions

/// Pure translation between the in-process queue model and the remote wire
/// shape. Kept free of the gateway, the session, and SwiftUI so the mapping
/// can be unit-tested on its own — it is the single place that knows how a
/// `QueuedPrompt` becomes something a browser can render.
public enum RemoteQueueProjection: Sendable {
    /// Items the native queue list hides are left out too (see
    /// `QueuedPrompt.isShownToUser`).
    public static func project(_ items: [QueuedPrompt]) -> [RemoteQueuedPrompt] {
        items.filter(\.isShownToUser).map { item in
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
                lastError: item.lastError,
                scheduledAt: item.scheduledAt.map { $0.timeIntervalSince1970 * 1_000 },
                canRemove: item.canRemoveFromQueue)
        }
    }

    /// Queue-count badge value. Mirrors `ACPSession.visibleQueueCount`: an
    /// in-flight `.sending` head is rendered as its own bubble but is not
    /// part of the "still waiting" count.
    public static func visibleCount(_ items: [RemoteQueuedPrompt]) -> Int {
        items.reduce(0) { $0 + ($1.status == "sending" ? 0 : 1) }
    }

    public static func plainText(from draft: ACPComposerDraft) -> String {
        draft.remoteQueuePlainText
    }
}
