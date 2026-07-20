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
    private(set) var lastActionSummary: String?

    /// Returns false when another action is already running (one at a time).
    func beginAction(_ action: GGStackActionKind) -> Bool {
        guard inFlightAction == nil else { return false }
        inFlightAction = action
        if lastActionSummary != nil { lastActionSummary = nil }
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
    func setActionSummary(_ message: String) { lastActionSummary = message }

    /// One-line result for a completed sync, from the accumulated stream
    /// events. Nil unless the terminal `.summary` event arrived (an errored
    /// or cancelled sync produces no summary line).
    static func syncSummaryLine(from events: [GGSyncEvent]) -> String? {
        guard events.contains(.summary) else { return nil }
        let pushed = events.filter { if case .pushDone = $0 { return true } else { return false } }.count
        let created = events.filter { if case .prCreated = $0 { return true } else { return false } }.count
        var parts = ["Synced"]
        if pushed > 0 { parts.append("\(pushed) pushed") }
        if created > 0 { parts.append("\(created) PR\(created == 1 ? "" : "s") created") }
        return parts.joined(separator: " · ")
    }

    static func landSummaryLine(landedCount: Int) -> String? {
        guard landedCount > 0 else { return nil }
        return "Landed \(landedCount) PR\(landedCount == 1 ? "" : "s")"
    }
}
