import Foundation
import Combine

/// Narrow observable holder for the rapidly-mutating slice of session
/// state (transcript + stream state + pending permission). Lives inside
/// `ACPSession`. Views that only care about the transcript can observe
/// this instead of the full `ACPSession`, so updates to model/mode/setup
/// state no longer invalidate the message list.
@MainActor
final class ACPTranscript: ObservableObject {
    @Published var messages: [ACPMessage] = []
    @Published var streamingState: ACPSession.StreamingState = .idle
    @Published var pendingPermission: ACPSession.PendingPermission?
    /// Tick incremented on every streaming chunk that mutates an existing
    /// agent/thought buffer. The buffer itself publishes (so the row's
    /// inner Text re-renders), but the transcript array doesn't change —
    /// without this tick, `ACPMessageList`'s body wouldn't re-evaluate
    /// and the tail-scroll signature wouldn't recompute, so long replies
    /// drift below the viewport mid-stream. Body re-eval is cheap because
    /// stableId + StreamingText identity equality keep the ForEach row
    /// tree stable across ticks.
    @Published var streamingTick: UInt32 = 0

    /// Render window: `ACPMessageList` draws `messages[visibleHead...]`.
    /// Reset to `max(0, messages.count - tailWindow)` after hydration so
    /// long transcripts paint quickly; user can scroll up or click the
    /// "Earlier messages…" affordance to reveal older rows in chunks of
    /// `tailWindow`.
    @Published var visibleHead: Int = 0

    /// Number of rows revealed per backfill step. Tuned for chat-style
    /// content where a screenful is a few rows; bigger steps feel like
    /// loading state, smaller steps require too many clicks.
    static let tailWindow: Int = 30

    // MARK: - Per-message markdown caches

    private var markdownCaches: [String: ACPMarkdownBlockCache] = [:]

    func markdownCache(forMessage id: String) -> ACPMarkdownBlockCache {
        if let c = markdownCaches[id] { return c }
        let c = ACPMarkdownBlockCache()
        markdownCaches[id] = c
        return c
    }

    func dropMarkdownCache(forMessage id: String) {
        markdownCaches.removeValue(forKey: id)
    }

    /// Clear all per-message caches; call when the transcript itself is
    /// discarded (e.g. session close).
    func resetMarkdownCaches() {
        markdownCaches.removeAll()
    }

    /// Items of the plan emitted for the current turn — the latest `.plan`
    /// message that comes after the latest `.user` prompt. Returns nil
    /// when no plan has arrived for this turn yet, even if an older turn
    /// left a plan behind. The toolbar pill renders the *current* turn's
    /// work, not stale progress from a previous prompt.
    var currentPlan: [ACPMessage.PlanItem]? {
        for m in messages.reversed() {
            if case .user = m { return nil }
            if case .plan(_, let items) = m { return items }
        }
        return nil
    }

    // MARK: - Render window helpers

    /// Reset `visibleHead` to show the last `tailWindow` messages. Call
    /// after hydration applies a transcript. No-op for transcripts shorter
    /// than `tailWindow`.
    func resetWindowToTail() {
        visibleHead = max(0, messages.count - Self.tailWindow)
    }

    /// Reveal one more `tailWindow`-sized chunk of older messages.
    /// Clamps at zero. Idempotent at the head.
    func stepHeadBack() {
        visibleHead = max(0, visibleHead - Self.tailWindow)
    }
}
