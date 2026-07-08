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
    @Published var pendingQuestion: ACPSession.PendingQuestion?
    /// Tick incremented on every streaming chunk that mutates an existing
    /// agent/thought buffer. The buffer itself publishes (so the row's
    /// inner Text re-renders), but the transcript array doesn't change —
    /// without this tick, `ACPMessageList`'s body wouldn't re-evaluate
    /// and the tail-scroll signature wouldn't recompute, so long replies
    /// drift below the viewport mid-stream. Body re-eval is cheap because
    /// stableId + StreamingText identity equality keep the ForEach row
    /// tree stable across ticks.
    @Published var streamingTick: UInt32 = 0
    /// True while post-hydration tail-first backfill is materialising older
    /// persisted rows. This is separate from `visibleHead`: a non-zero head
    /// means older rows are available behind the render window, not that an
    /// async load is still running.
    @Published var isBackfillingOlderMessages: Bool = false

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

    /// Stable ids of streaming text rows whose prompt has completed. A
    /// later ACP text chunk must start a fresh row instead of appending
    /// directly to any completed output.
    var completedOutputBoundaryMessageIds: Set<String> = []

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

    #if DEBUG
    /// Sum of `byteEstimate` over every retained cache. Bounded by the number
    /// of messages with at least one render pass.
    var markdownCacheByteEstimate: UInt64 {
        markdownCaches.values.reduce(0) { $0 + $1.byteEstimate }
    }
    #endif

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
    /// (See also `latestPlan`, which is turn-stable and treats an empty plan as nil.)
    var currentPlan: [ACPMessage.PlanItem]? {
        for m in messages.reversed() {
            if case .user = m { return nil }
            if case .plan(_, let items) = m { return items }
        }
        return nil
    }

    /// The most recent plan emitted in this session, ignoring turn
    /// boundaries. Unlike `currentPlan`, this survives the gap between
    /// a fresh user prompt and the next `.plan` arrival — so the sidebar
    /// can stay visible across turns per spec §6 ("stays until the next
    /// plan or session reset").
    ///
    /// Returns nil when no plan message has ever arrived, or when the
    /// most recent plan is empty. Note: unlike `currentPlan`, which returns an empty array for an empty current-turn plan, `latestPlan` normalises empty to nil — the sidebar uses this to decide whether to render at all.
    ///
    /// **Sidebar-only intent.** The toolbar pill deliberately keeps reading
    /// `currentPlan` so it reflects the *active* turn — a per-turn signal
    /// matches the pill's "what's the agent doing right now" framing. The
    /// turn-stable semantics here exist only because the sidebar wants the
    /// previous plan to linger across the brief gap when a new user prompt
    /// has landed but the next `.plan` hasn't yet arrived.
    var latestPlan: [ACPMessage.PlanItem]? {
        for m in messages.reversed() {
            if case .plan(_, let items) = m {
                return items.isEmpty ? nil : items
            }
        }
        return nil
    }

    // MARK: - Render window helpers

    /// Reset `visibleHead` to show the last `tailWindow` messages. Call
    /// after hydration applies a transcript. No-op for transcripts shorter
    /// than `tailWindow`.
    func resetWindowToTail() {
        setVisibleHead(max(0, messages.count - Self.tailWindow))
    }

    /// Reveal one more `tailWindow`-sized chunk of older messages.
    /// Clamps at zero. Idempotent at the head.
    func stepHeadBack() {
        visibleHead = max(0, visibleHead - Self.tailWindow)
    }

    /// Move the render window head, dropping markdown caches for any message
    /// whose index is now below the new head. No-op if `newHead` is not greater
    /// than the current `visibleHead`. Use this instead of writing
    /// `visibleHead` directly when advancing the window.
    func setVisibleHead(_ newHead: Int) {
        let clamped = max(0, min(newHead, messages.count))
        guard clamped > visibleHead else {
            visibleHead = clamped
            return
        }
        for i in visibleHead..<clamped {
            trimHiddenMessage(at: i)
        }
        visibleHead = clamped
    }

    /// Shift the render window after hidden messages are prepended at the
    /// front. This trims every row below the shifted head because prepended
    /// rows never passed through `setVisibleHead`.
    func shiftVisibleHeadAfterPrepending(_ insertedCount: Int) {
        guard insertedCount > 0 else { return }
        let shiftedHead = max(0, min(visibleHead + insertedCount, messages.count))
        for i in 0..<shiftedHead {
            trimHiddenMessage(at: i)
        }
        visibleHead = shiftedHead
    }

    private func trimHiddenMessage(at index: Int) {
        markdownCaches.removeValue(forKey: messages[index].stableId)
        if case .toolCall(var tc) = messages[index] {
            if tc.status != "in_progress", tc.status != "pending" {
                tc.truncateForOffWindow()
                messages[index] = .toolCall(tc)
            }
        }
    }

    #if DEBUG
    var markdownCacheCountForTests: Int { markdownCaches.count }
    func hasMarkdownCacheForTests(messageId: String) -> Bool {
        markdownCaches[messageId] != nil
    }
    #endif
}
