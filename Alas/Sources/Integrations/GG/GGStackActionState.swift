import Foundation
import Observation

/// Which gg mutation is running / paused.
enum GGStackActionKind: Equatable, Sendable {
    case amendCurrent, absorbStaged, checkout, drop, unstack, reorder, restack
    case rebase, sync, land, clean, continueOp, abortOp, undo, split
}

/// What a confirmed `land` should do: land everything currently landable, or
/// stop at a specific entry the user picked from the stack drawer.
enum GGLandRequest: Equatable {
    case ready
    case until(entryId: String, title: String)
}

/// A gg operation left paused on a conflict (rebase-in-progress), awaiting
/// `gg continue` / `gg abort`.
struct GGPausedOperation: Equatable, Sendable {
    let pausedBy: GGStackActionKind
}

struct GGCompletedRecoveryOperation: Equatable, Sendable {
    let operationID: String
    let headSHA: String
}

/// Per-worktree observable backing the stack-mode drawer's actions. The
/// stack-mode analogue of `ReviewLoopState`'s in-flight/error surface.
@MainActor
@Observable
final class GGStackActionState {
    private(set) var inFlightAction: GGStackActionKind?
    private(set) var syncProgress: [GGSyncEvent] = []
    private(set) var syncHasTerminalFailure = false
    private(set) var lastError: String?
    private(set) var lastErrorAction: GGStackActionKind?
    private(set) var pausedOperation: GGPausedOperation?
    private(set) var completedRecoveryOperation: GGCompletedRecoveryOperation?
    private(set) var lastActionSummary: String?
    @ObservationIgnored private(set) var actionGeneration: UInt = 0

    /// Returns false when another action is already running (one at a time).
    func beginAction(_ action: GGStackActionKind) -> Bool {
        guard inFlightAction == nil else { return false }
        if !syncProgress.isEmpty { syncProgress = [] }
        if syncHasTerminalFailure { syncHasTerminalFailure = false }
        clearError()
        if lastActionSummary != nil { lastActionSummary = nil }
        actionGeneration &+= 1
        inFlightAction = action
        return true
    }

    func endAction(_ action: GGStackActionKind) {
        guard inFlightAction == action else { return }
        inFlightAction = nil
    }

    func appendSyncEvent(_ event: GGSyncEvent) { syncProgress.append(event) }
    func clearSyncProgress() { if !syncProgress.isEmpty { syncProgress = [] } }
    var canDismissCompletedSyncFailure: Bool {
        inFlightAction == nil && pausedOperation == nil && syncHasTerminalFailure
    }
    func dismissCompletedSyncFailure() {
        guard canDismissCompletedSyncFailure else { return }
        syncProgress = []
        syncHasTerminalFailure = false
        if lastErrorAction == .sync { clearError() }
    }
    func markSyncTerminalFailure() {
        if !syncHasTerminalFailure { syncHasTerminalFailure = true }
    }
    func shouldPublishError(
        forActionGeneration generation: UInt,
        action: GGStackActionKind
    ) -> Bool {
        actionGeneration == generation && lastErrorAction != action
    }
    func setError(_ message: String, for action: GGStackActionKind? = nil) {
        lastError = message
        lastErrorAction = action
    }
    func clearError() {
        if lastError != nil { lastError = nil }
        if lastErrorAction != nil { lastErrorAction = nil }
    }
    func setPaused(_ paused: GGPausedOperation) {
        if pausedOperation != paused { pausedOperation = paused }
        if completedRecoveryOperation != nil { completedRecoveryOperation = nil }
    }
    func clearPaused() { if pausedOperation != nil { pausedOperation = nil } }
    func setCompletedRecoveryOperation(_ operation: GGCompletedRecoveryOperation) {
        if completedRecoveryOperation != operation { completedRecoveryOperation = operation }
    }
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

    /// One-line result for a completed land. Distinguishes merged PRs from
    /// entries only queued into a merge train (GitLab auto-merge: gg reports
    /// `queued`/`already_queued`), so the drawer never claims a queued MR was
    /// landed. Nil when nothing landed.
    static func landSummaryLine(from landed: [GGLandedEntry]) -> String? {
        guard !landed.isEmpty else { return nil }
        let queued = landed.filter { $0.action == "queued" || $0.action == "already_queued" }.count
        let merged = landed.count - queued
        var parts: [String] = []
        if merged > 0 { parts.append("Landed \(merged) PR\(merged == 1 ? "" : "s")") }
        if queued > 0 { parts.append("Queued \(queued) PR\(queued == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
