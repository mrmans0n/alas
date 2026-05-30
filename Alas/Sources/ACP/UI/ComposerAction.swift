/// Mutually-exclusive states the composer's single action button can be in.
/// Derived from `(streamingState, hasText, agentState)` via
/// `composerAction(...)`. The view layer renders one capsule per case.
enum ComposerAction: Equatable {
    /// Nothing to do — render nothing. Composer toolbar reflows naturally.
    case hidden
    /// Idle agent + non-empty composer. Tapping submits the prompt.
    case send
    /// Busy agent + non-empty composer. Primary action enqueues the prompt;
    /// the menu exposes steer and stop.
    case queue(menu: [ComposerMenuItem])
    /// Busy agent + empty composer. Tapping cancels the in-flight turn.
    case stop
}

/// Items that appear in the chevron menu when `ComposerAction == .queue`.
/// Ordered as they appear top-to-bottom in the menu.
enum ComposerMenuItem: Hashable {
    case steer
    case stop
}

/// Pure derive — no SwiftUI imports, no session/runner references.
/// Exhaustively unit-tested in `ComposerActionTests`.
///
/// The agent lifecycle intentionally does not disable or hide a non-empty
/// composer: `ACPSessionManager.submit` accepts prompts while disconnected,
/// failed, idle, or spawning so the user's prompt can kick recovery.
func composerAction(
    streamingState: ACPSession.StreamingState,
    hasText: Bool,
    agentState: ACPSession.AgentState
) -> ComposerAction {
    switch agentState {
    case .idle, .spawning, .ready, .disconnected, .failed(_):
        break
    }

    switch streamingState {
    case .idle:
        return hasText ? .send : .hidden
    case .sending, .streaming, .awaitingPermission:
        return hasText ? .queue(menu: [.steer, .stop]) : .stop
    }
}
