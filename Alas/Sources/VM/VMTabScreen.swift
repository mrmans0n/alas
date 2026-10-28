import Foundation

/// Which screen a worktree's VM tab shows.
enum VMTabScreen: Equatable {
    case loading
    case running
    case starting
    case slotChoice(candidates: [String])
    case runningElsewhere(label: String)
    /// The golden VM awaiting Setup Assistant.
    case goldenSetup(build: String)
    /// No golden image yet: download and install one.
    case setup
    case createVM
    case stopped

    /// A worktree that has its own VM always shows that VM's states; golden
    /// setup screens are only for worktrees that have none yet.
    static func resolve(
        runningHere: Bool,
        startingHere: Bool,
        slotChoice: [String]?,
        runningElsewhere: String?,
        loaded: Bool,
        hasVM: Bool,
        goldenAvailable: Bool,
        installerPhase: GoldenImageInstaller.Phase
    ) -> VMTabScreen {
        if runningHere { return .running }
        if startingHere { return .starting }
        if let slotChoice { return .slotChoice(candidates: slotChoice) }
        if let runningElsewhere { return .runningElsewhere(label: runningElsewhere) }
        if !loaded { return .loading }
        if hasVM { return .stopped }
        switch installerPhase {
        case .awaitingSetup(let build): return .goldenSetup(build: build)
        case .downloading, .installing, .failed: return .setup
        case .idle, .sealed: return goldenAvailable ? .createVM : .setup
        }
    }
}
