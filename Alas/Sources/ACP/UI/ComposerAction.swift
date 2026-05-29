import Foundation

/// Mutually-exclusive states the composer's single action button can be in.
/// Derived from `(streamingState, hasText, attached, disconnected)` via
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
enum ComposerMenuItem: Equatable {
    case steer
    case stop
}

/// Pure derive — no SwiftUI imports, no session/runner references.
/// Exhaustively unit-tested in `ComposerActionTests`.
///
/// Priority:
/// 1. `disconnected` dominates everything → `.hidden`.
/// 2. `attached == false` (connecting) → `.hidden`.
/// 3. Otherwise dispatch on `(streamingState, hasText)`.
func composerAction(
    streamingState: ACPSession.StreamingState,
    hasText: Bool,
    attached: Bool,
    disconnected: Bool
) -> ComposerAction {
    if disconnected { return .hidden }
    if !attached    { return .hidden }

    switch streamingState {
    case .idle:
        return hasText ? .send : .hidden
    case .sending, .streaming, .awaitingPermission:
        return hasText ? .queue(menu: [.steer, .stop]) : .stop
    }
}
