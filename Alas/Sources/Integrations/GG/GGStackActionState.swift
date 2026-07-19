import Foundation
import Observation

/// Which gg mutation is running / paused.
enum GGStackActionKind: Equatable {
    case sync, land, clean, continueOp, abortOp, checkout
}

/// What a confirmed `land` should do: land everything currently landable, or
/// stop at a specific entry the user picked from the stack drawer.
enum GGLandRequest: Equatable {
    case ready
    case until(entryId: String, title: String)
}

/// A gg operation left paused on a conflict (rebase-in-progress), awaiting
/// `gg continue` / `gg abort`.
struct GGPausedOperation: Equatable {
    let pausedBy: GGStackActionKind
}

/// Per-worktree observable backing the stack-mode drawer's actions. The
/// stack-mode analogue of `ReviewLoopState`'s in-flight/error surface.
@MainActor
@Observable
final class GGStackActionState {
    private(set) var inFlightAction: GGStackActionKind?
    private(set) var syncProgress: [GGSyncEvent] = []
    private(set) var lastError: String?
    private(set) var pausedOperation: GGPausedOperation?

    /// Returns false when another action is already running (one at a time).
    func beginAction(_ action: GGStackActionKind) -> Bool {
        guard inFlightAction == nil else { return false }
        inFlightAction = action
        return true
    }

    func endAction(_ action: GGStackActionKind) {
        guard inFlightAction == action else { return }
        inFlightAction = nil
    }

    func appendSyncEvent(_ event: GGSyncEvent) { syncProgress.append(event) }
    func clearSyncProgress() { if !syncProgress.isEmpty { syncProgress = [] } }
    func setError(_ message: String) { lastError = message }
    func clearError() { if lastError != nil { lastError = nil } }
    func setPaused(_ paused: GGPausedOperation) { if pausedOperation != paused { pausedOperation = paused } }
    func clearPaused() { if pausedOperation != nil { pausedOperation = nil } }
}
