import Foundation

/// Which queued prompts get a bubble in the transcript's synthetic tail, and
/// which drags between them are legal.
enum ACPTranscriptQueuePolicy {
    nonisolated static func shouldRenderQueueBubble(status: QueuedPrompt.Status) -> Bool {
        switch status {
        case .pending:
            return true
        case .sending:
            return false
        }
    }

    /// Whether `item` gets a row in the "Up next" list. A delegated prompt
    /// (a child's report, a parent's prompt) does not while it waits: it is
    /// not the user's to edit, reorder, or remove, and it dispatches on its
    /// own once the current turn ends. A failed one does, so it can be
    /// retried or removed (see `QueuedPrompt.isShownToUser`).
    nonisolated static func shouldRenderQueueBubble(_ item: QueuedPrompt) -> Bool {
        item.isShownToUser && shouldRenderQueueBubble(status: item.status)
    }

    nonisolated static func queueHeaderCount(queue: [QueuedPrompt]) -> Int {
        queue.reduce(0) { count, item in
            count + (shouldRenderQueueBubble(item) ? 1 : 0)
        }
    }

    /// 1-based dispatch position of the item at `idx` among the items that
    /// actually render a row (excluding any in-flight `.sending` head and any
    /// delegated prompt). `idx` must itself render; every other rendered
    /// item before it, whether it's a plain queued prompt or a scheduled
    /// one, counts toward its position — scheduled items still occupy a slot
    /// in the visible list, they just dispatch on their own clock instead of
    /// FIFO order.
    nonisolated static func queuePosition(at idx: Int, queue: [QueuedPrompt]) -> Int {
        queue[..<idx].filter { shouldRenderQueueBubble($0) }.count + 1
    }

    /// The `moveInQueue` destination for a one-row "Move up" (`step == -1`)
    /// or "Move down" (`step == 1`) from `idx`: the index of the neighboring
    /// rendered row, skipping hidden delegated items so the move is never a
    /// visual no-op. Nil when there is no rendered neighbor that way.
    nonisolated static func adjacentRenderedIndex(from idx: Int, step: Int, queue: [QueuedPrompt]) -> Int? {
        var candidate = idx + step
        while candidate >= 0, candidate < queue.count {
            if shouldRenderQueueBubble(queue[candidate]) { return candidate }
            candidate += step
        }
        return nil
    }

    nonisolated static func canDropQueuedItem(
        sourceStatus: QueuedPrompt.Status?,
        targetStatus: QueuedPrompt.Status
    ) -> Bool {
        sourceStatus == .pending && targetStatus == .pending
    }

    /// Whether `ACPSession.moveInQueue(from:to:)` would actually reorder
    /// anything for this `(src, dst)` pair, so the row's "Move up" /
    /// "Move down" affordances can disable instead of silently no-opping on
    /// click. Mirrors `moveInQueue`'s own guards exactly — kept in sync by
    /// `ACPSessionQueueAPITests`.
    nonisolated static func canMoveQueueItem(from src: Int, to dst: Int, queue: [QueuedPrompt]) -> Bool {
        guard src >= 0, src < queue.count, dst >= 0, dst <= queue.count, src != dst else { return false }
        if queue[src].status == .sending { return false }
        if queue.first?.status == .sending, dst == 0 { return false }
        // Moving the last item "past the end" (dst == queue.count) is a
        // no-op: removing it and reinserting at `min(dst, queue.count)`
        // lands it in the exact slot it started in. Reject so "Move down"
        // isn't shown as enabled on the tail item without ever reordering
        // anything.
        if src == queue.count - 1, dst == queue.count { return false }
        if let firstScheduled = queue.firstIndex(where: { $0.status == .pending && $0.scheduledAt != nil }),
           (queue[src].scheduledAt != nil || dst >= firstScheduled) {
            return false
        }
        return true
    }

    /// Whether a queue mutation is allowed for the session's current
    /// ownership.
    ///
    /// Callers MUST evaluate this inside the callback, at invocation time —
    /// not when building the row's callbacks. `ACPTranscriptScroller` retains
    /// a mounted queue row (and therefore the closures its build captured)
    /// for as long as the row's equality token is unchanged, and that token
    /// deliberately covers only rendering/behavior inputs it can compare
    /// (`QueueBubbleTokenInputs`: item, index, typography, derived position
    /// and move-eligibility, plus theme and width) — closures are not
    /// `Equatable`, so callback identity cannot be part of it.
    ///
    /// Deciding ownership up front (`isMirror ? {} : realAction`) therefore
    /// bakes a stale answer into a retained row whenever a session changes
    /// hands while its queue is otherwise untouched: no-op callbacks survive
    /// a takeover (buttons look live but do nothing), and live callbacks
    /// survive a stand-down (a mirror can still mutate its in-memory queue).
    nonisolated static func allowsQueueMutation(isMirror: Bool) -> Bool {
        !isMirror
    }
}
