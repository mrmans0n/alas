import Foundation
import Combine

/// Narrow observable holder for the rapidly-mutating slice of session
/// state (transcript + stream state + pending permission). Lives inside
/// `ACPSession`. Views that only care about the transcript can observe
/// this instead of the full `ACPSession`, so updates to model/mode/setup
/// state no longer invalidate the message list.
@MainActor
final class ACPTranscript: ObservableObject {
    @Published var messages: [ACPMessage] = [] {
        didSet {
            refreshPlanCaches()
        }
    }
    @Published var streamingState: ACPSession.StreamingState = .idle
    @Published var pendingPermission: ACPSession.PendingPermission?
    @Published var pendingQuestion: ACPSession.PendingQuestion?
    @Published var pendingUserInputs: [ACPUserInputRequest] = []
    @Published var urlElicitationWaits: [ACPURLElicitationWait] = []
    /// Items of the plan emitted for the current turn. Updated when the
    /// transcript array changes so high-frequency streaming ticks do not scan
    /// the full message list from `ACPSessionView` / plan UI bodies.
    @Published private(set) var currentPlan: [ACPMessage.PlanItem]?
    /// The most recent non-empty plan emitted in this session, ignoring turn
    /// boundaries. Sidebar-only signal that intentionally survives the gap
    /// between a new user prompt and the next `.plan` arrival.
    @Published private(set) var latestPlan: [ACPMessage.PlanItem]?
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

    /// Render window: `ACPMessageList` draws `messages[visibleHead..<visibleTail]`.
    /// Reset to `max(0, messages.count - tailWindow)` after hydration so
    /// long transcripts paint quickly; user can scroll up or click the
    /// "Earlier messages…" affordance to reveal older rows in chunks of
    /// `tailWindow`.
    @Published var visibleHead: Int = 0
    /// Exclusive upper bound of the render window. `nil` means the live tail.
    /// Non-tail restored anchors use this to avoid asking SwiftUI to keep every
    /// newer transcript row in a single lazy-stack layout pass.
    @Published var visibleTail: Int?

    /// Number of rows revealed per backfill step. Tuned for chat-style
    /// content where a screenful is a few rows; bigger steps feel like
    /// loading state, smaller steps require too many clicks.
    static let tailWindow: Int = 30
    /// Upper bound for non-tail render windows. A few chunks gives enough room
    /// for natural scrolling while keeping `ForEach` input bounded.
    static let maxVisibleRows: Int = tailWindow * 3

    /// Stable ids of streaming text rows whose prompt has completed. A
    /// later ACP text chunk must start a fresh row instead of appending
    /// directly to any completed output.
    var completedOutputBoundaryMessageIds: Set<String> = []

    // MARK: - Per-message markdown caches

    private var markdownCaches: [String: ACPMarkdownBlockCache] = [:]
    private var stableIdCache: [ACPMessage.StableIdentityKey: String] = [:]

    func stableId(for message: ACPMessage) -> String {
        let key = message.stableIdentityKey
        if let cached = stableIdCache[key] {
            return cached
        }
        let stableId = ACPMessage.stableId(for: key)
        stableIdCache[key] = stableId
        return stableId
    }

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

    private func refreshPlanCaches() {
        var newCurrentPlan: [ACPMessage.PlanItem]?
        for m in messages.reversed() {
            if case .user = m { break }
            if case .plan(_, let items) = m {
                newCurrentPlan = items
                break
            }
        }

        var newLatestPlan: [ACPMessage.PlanItem]?
        for m in messages.reversed() {
            if case .plan(_, let items) = m {
                newLatestPlan = items.isEmpty ? nil : items
                break
            }
        }
        if currentPlan != newCurrentPlan {
            currentPlan = newCurrentPlan
        }
        if latestPlan != newLatestPlan {
            latestPlan = newLatestPlan
        }
    }

    // MARK: - Render window helpers

    /// Reset `visibleHead` to show the last `tailWindow` messages. Call
    /// after hydration applies a transcript. No-op for transcripts shorter
    /// than `tailWindow`.
    func resetWindowToTail() {
        setVisibleWindow(head: max(0, messages.count - Self.tailWindow), tail: nil)
    }

    /// Reveal one more `tailWindow`-sized chunk of older messages.
    /// Clamps at zero. Idempotent at the head.
    func stepHeadBack() {
        let currentTail = visibleTailBound
        let newHead = max(0, visibleHead - Self.tailWindow)
        let boundedTail = min(messages.count, newHead + Self.maxVisibleRows)
        setVisibleWindow(head: newHead, tail: min(currentTail, boundedTail))
    }

    /// Reveal one more chunk of newer messages while keeping the row currently
    /// near the viewport top inside the bounded window when possible.
    func stepTailForward(preserving preservedIndex: Int?) {
        let currentTail = visibleTailBound
        guard currentTail < messages.count else { return }
        var newTail = min(messages.count, currentTail + Self.tailWindow)
        if let preservedIndex,
           preservedIndex >= visibleHead,
           preservedIndex < currentTail {
            let preservingTail = min(newTail, preservedIndex + Self.maxVisibleRows)
            if preservingTail > currentTail {
                newTail = preservingTail
            }
        }
        guard newTail > currentTail else { return }
        let boundedHead = max(0, newTail - Self.maxVisibleRows)
        setVisibleWindow(head: boundedHead, tail: newTail)
    }

    /// Restore around a remembered non-tail row without rendering the entire
    /// suffix from that row to the transcript tail.
    func setVisibleWindow(containing index: Int) {
        let head = max(0, min(index, messages.count))
        let tail = min(messages.count, head + Self.maxVisibleRows)
        setVisibleWindow(head: head, tail: tail)
    }

    /// Move the render window head, dropping markdown caches for any message
    /// whose index is now below the new head. No-op if `newHead` is not greater
    /// than the current `visibleHead`. Use this instead of writing
    /// `visibleHead` directly when advancing the window.
    func setVisibleHead(_ newHead: Int) {
        setVisibleWindow(head: newHead, tail: nil)
    }

    /// Shift the render window after hidden messages are prepended at the
    /// front. This trims every row below the shifted head because prepended
    /// rows never passed through `setVisibleHead`.
    func shiftVisibleHeadAfterPrepending(_ insertedCount: Int) {
        guard insertedCount > 0 else { return }
        let shiftedHead = max(0, min(visibleHead + insertedCount, messages.count))
        let shiftedTail = visibleTail.map { max(shiftedHead, min($0 + insertedCount, messages.count)) }
        for i in 0..<shiftedHead {
            trimHiddenMessage(at: i)
        }
        visibleHead = shiftedHead
        visibleTail = shiftedTail
    }

    var visibleTailBound: Int {
        max(visibleHead, min(visibleTail ?? messages.count, messages.count))
    }

    private func setVisibleWindow(head newHead: Int, tail newTail: Int?) {
        let clampedHead = max(0, min(newHead, messages.count))
        let clampedTail = newTail.map { max(clampedHead, min($0, messages.count)) }
        let normalizedTail = clampedTail
        guard clampedHead != visibleHead || normalizedTail != visibleTail else { return }
        if clampedHead > visibleHead {
            for i in visibleHead..<clampedHead {
                trimHiddenMessage(at: i)
            }
        }
        let oldTail = visibleTailBound
        let newTail = normalizedTail ?? messages.count
        if newTail < oldTail {
            for i in newTail..<oldTail {
                trimHiddenMessage(at: i)
            }
        }
        visibleHead = clampedHead
        visibleTail = normalizedTail
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
