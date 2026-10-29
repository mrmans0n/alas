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
    /// The worktree's own VM is stopped while the base image is being
    /// customized, from another tab or before a relaunch.
    case stoppedWhileCustomizing

    /// A worktree that has its own VM shows that VM's states; with a golden
    /// awaiting setup (the base image being customized, since the worktree
    /// already cloned a sealed one) only the tab customizing it shows golden
    /// setup. Install screens are only for worktrees that have no VM yet.
    static func resolve(
        runningHere: Bool,
        startingHere: Bool,
        slotChoice: [String]?,
        runningElsewhere: String?,
        loaded: Bool,
        hasVM: Bool,
        customizingHere: Bool,
        goldenAvailable: Bool,
        installerPhase: GoldenImageInstaller.Phase
    ) -> VMTabScreen {
        if runningHere { return .running }
        if startingHere { return .starting }
        if let slotChoice { return .slotChoice(candidates: slotChoice) }
        if let runningElsewhere { return .runningElsewhere(label: runningElsewhere) }
        if !loaded { return .loading }
        switch installerPhase {
        case .awaitingSetup(let build):
            return hasVM && !customizingHere ? .stoppedWhileCustomizing : .goldenSetup(build: build)
        case _ where hasVM: return .stopped
        case .downloading, .installing, .failed: return .setup
        case .idle, .sealed: return goldenAvailable ? .createVM : .setup
        }
    }
}
