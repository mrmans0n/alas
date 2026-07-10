import Foundation

enum ACPSubmitIntent: Equatable { case auto, steer }

enum ACPSubmitRoute: Equatable {
    /// State is idle AND queue is empty — send the prompt directly.
    case sendNow
    /// State is busy OR queue is already non-empty — append to the queue.
    /// Routing the second case through the queue (not directly) keeps the
    /// flusher's FIFO order intact even if the user submits another prompt
    /// in the microsecond gap between state→.idle and the flusher firing.
    case enqueue
    /// User explicitly steered: cancel the in-flight turn (if any), clear
    /// the queue, and send the new prompt as a fresh turn. Falls back to
    /// `.sendNow` only when there's literally nothing to interrupt
    /// (idle + empty queue) — handled by the resolver.
    case steer
    /// Empty composer — nothing to send. Never cancels a turn.
    case noOp

    static func resolve(intent: ACPSubmitIntent,
                        state: ACPSession.StreamingState,
                        queueEmpty: Bool,
                        blocksEmpty: Bool,
                        hasPendingInput: Bool = false,
                        inFlightSteer: Bool = false) -> ACPSubmitRoute
    {
        if blocksEmpty { return .noOp }
        // While a steer is mid-flight, `userCancel` has already flipped
        // streamingState to .idle but the redirect's `sendNow` hasn't
        // installed itself yet. Forcing every non-empty submit through
        // the queue closes that window — the redirect fires first, and
        // whatever the user typed during it drains afterwards instead of
        // racing the redirect.
        if inFlightSteer { return .enqueue }
        let canSendNow = state == .idle && queueEmpty && !hasPendingInput
        switch intent {
        case .auto:
            return canSendNow ? .sendNow : .enqueue
        case .steer:
            return canSendNow ? .sendNow : .steer
        }
    }
}
