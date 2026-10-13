import Foundation

/// The parsed markdown of a transcript's messages, kept next to the renderer
/// rather than in the core transcript. A message's cache goes when its row
/// leaves the visible window, and all of them when the transcript is
/// discarded.
@MainActor
final class ACPTranscriptRenderCaches: ACPTranscriptRenderState {
    private var caches: [String: ACPMarkdownBlockCache] = [:]
    private var windowSubscription: ChangeSubscription?

    /// The transcript's caches, installed on first use.
    static func of(_ transcript: ACPTranscript) -> ACPTranscriptRenderCaches {
        if let installed = transcript.renderState as? ACPTranscriptRenderCaches {
            return installed
        }
        let caches = ACPTranscriptRenderCaches()
        caches.windowSubscription = transcript.rowsLeftWindow.observe { [weak caches] ids in
            for id in ids {
                caches?.caches.removeValue(forKey: id)
            }
        }
        transcript.renderState = caches
        return caches
    }

    func cache(forMessage id: String) -> ACPMarkdownBlockCache {
        if let cache = caches[id] { return cache }
        let cache = ACPMarkdownBlockCache()
        caches[id] = cache
        return cache
    }

    #if DEBUG
    /// Sum of `byteEstimate` over every retained cache.
    var byteEstimate: UInt64 {
        caches.values.reduce(0) { $0 + $1.byteEstimate }
    }

    var countForTests: Int { caches.count }

    func hasCacheForTests(messageId: String) -> Bool {
        caches[messageId] != nil
    }
    #endif
}
