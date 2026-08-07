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

    nonisolated static func queueHeaderCount(statuses: [QueuedPrompt.Status]) -> Int {
        statuses.reduce(0) { count, status in
            count + (shouldRenderQueueBubble(status: status) ? 1 : 0)
        }
    }

    nonisolated static func canDropQueuedItem(
        sourceStatus: QueuedPrompt.Status?,
        targetStatus: QueuedPrompt.Status
    ) -> Bool {
        sourceStatus == .pending && targetStatus == .pending
    }

    /// Whether a queue mutation is allowed for the session's current
    /// ownership.
    ///
    /// Callers MUST evaluate this inside the callback, at invocation time —
    /// not when building the row's callbacks. `ACPTranscriptScroller` retains
    /// a mounted queue row (and therefore the closures its build captured)
    /// for as long as the row's equality token is unchanged, and that token
    /// deliberately covers only rendering/behavior inputs it can compare
    /// (`QueueBubbleTokenInputs`: item, index, typography, plus theme and
    /// width) — closures are not `Equatable`, so callback identity cannot be
    /// part of it.
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
