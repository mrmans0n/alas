import Foundation

enum ACPSubmitIntent: Equatable { case auto, steer, schedule(Date) }

enum ACPSubmitRoute: Equatable {
    /// Session is idle, queue-empty, and has no active prompt.
    case sendNow
    /// State is busy OR queue is already non-empty — append to the queue.
    /// Routing the second case through the queue (not directly) keeps the
    /// flusher's FIFO order intact even if the user submits another prompt
    /// in the microsecond gap between state→.idle and the flusher firing.
    case enqueue
    /// Inject into the running turn where supported, otherwise interrupt and
    /// resend. Preserve the queue. An idle, queue-empty session sends normally.
    case steer
    /// Empty composer — nothing to send. Never cancels a turn.
    case noOp

    static func resolve(
        intent: ACPSubmitIntent,
        state: ACPSession.StreamingState,
        queueEmpty: Bool,
        blocksEmpty: Bool,
        hasPendingInput: Bool = false,
        inFlightSteer: Bool = false,
        hasActivePrompt: Bool = false
    ) -> ACPSubmitRoute
    {
        if blocksEmpty { return .noOp }
        // A steer can outlive the original prompt's completion or cancellation.
        // Queue subsequent submits until the follow-up's delivery is settled.
        if inFlightSteer { return .enqueue }
        let canSendNow = state == .idle && queueEmpty && !hasPendingInput && !hasActivePrompt
        switch intent {
        case .auto:
            return canSendNow ? .sendNow : .enqueue
        case .steer:
            return canSendNow ? .sendNow : .steer
        case .schedule:
            return .enqueue
        }
    }
}
