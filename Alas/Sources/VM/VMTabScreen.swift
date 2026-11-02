import AlasCore
import Foundation

/// Which screen a worktree's VM tab shows.
enum VMTabScreen: Equatable {
    /// A VM's guest helper, as far as the tab knows.
    enum HelperUpdate: Equatable {
        case none
        /// Missing or out of date: offer Update helper.
        case available
        case updating
    }

    case loading
    case running(updateHelper: Bool)
    case starting
    case slotChoice(candidates: [String])
    case runningElsewhere(label: String)
    /// The golden VM awaiting Setup Assistant.
    case goldenSetup(build: String, updateHelper: Bool)
    /// No golden image yet: download and install one.
    case setup
    case createVM
    case stopped
    /// The worktree's macOS VM is paused with its state saved.
    case paused(savedAt: Date)
    /// The worktree's own VM is stopped while the base image is being
    /// customized, from another tab or before a relaunch.
    case stoppedWhileCustomizing
    /// The VM restarts with a reinstalled helper.
    case updatingHelper

    /// A worktree that has its own VM shows that VM's states; with a golden
    /// awaiting setup (the base image being customized, since the worktree
    /// already cloned a sealed one) only the tab customizing it shows golden
    /// setup. Install screens are only for worktrees that have no VM yet.
    /// A helper update stops and restarts the VM, so it wins over the states
    /// that passes through. `helper` is the worktree VM's, `goldenHelper`
    /// the golden's awaiting setup.
    ///
    /// A Linux tab follows `linuxInstallerPhase` alone: its image has no
    /// setup by hand and no customizing, and it takes no macOS VM slot. Its
    /// helper update keeps the VM running, so it shows only while it runs.
    /// A paused VM shows paused wherever it would show stopped; Linux VMs never pause.
    static func resolve(
        guest: VMGuestOS = .macOS,
        runningHere: Bool,
        startingHere: Bool,
        slotChoice: [String]?,
        runningElsewhere: String?,
        loaded: Bool,
        hasVM: Bool,
        customizingHere: Bool,
        goldenAvailable: Bool,
        installerPhase: GoldenImageInstaller.Phase,
        linuxInstallerPhase: LinuxGoldenInstaller.Phase = .idle,
        helper: HelperUpdate,
        goldenHelper: HelperUpdate,
        pausedAt: Date? = nil
    ) -> VMTabScreen {
        if guest == .linux {
            return resolveLinux(
                runningHere: runningHere, startingHere: startingHere, runningElsewhere: runningElsewhere,
                loaded: loaded, hasVM: hasVM, goldenAvailable: goldenAvailable, installerPhase: linuxInstallerPhase,
                helper: helper)
        }
        if helper == .updating { return .updatingHelper }
        if runningHere { return .running(updateHelper: helper == .available) }
        if startingHere { return .starting }
        if let slotChoice { return .slotChoice(candidates: slotChoice) }
        if let runningElsewhere { return .runningElsewhere(label: runningElsewhere) }
        if !loaded { return .loading }
        let pausedScreen = pausedAt.map { VMTabScreen.paused(savedAt: $0) }
        switch installerPhase {
        case .awaitingSetup(let build):
            if hasVM && !customizingHere { return pausedScreen ?? .stoppedWhileCustomizing }
            if goldenHelper == .updating { return .updatingHelper }
            return .goldenSetup(build: build, updateHelper: goldenHelper == .available)
        case _ where hasVM: return pausedScreen ?? .stopped
        case .downloading, .installing, .provisioning, .failed: return .setup
        case .idle, .sealed: return goldenAvailable ? .createVM : .setup
        }
    }

    private static func resolveLinux(
        runningHere: Bool,
        startingHere: Bool,
        runningElsewhere: String?,
        loaded: Bool,
        hasVM: Bool,
        goldenAvailable: Bool,
        installerPhase: LinuxGoldenInstaller.Phase,
        helper: HelperUpdate
    ) -> VMTabScreen {
        if runningHere { return helper == .updating ? .updatingHelper : .running(updateHelper: helper == .available) }
        if startingHere { return .starting }
        if let runningElsewhere { return .runningElsewhere(label: runningElsewhere) }
        if !loaded { return .loading }
        if hasVM { return .stopped }
        switch installerPhase {
        case .downloading, .checking, .converting, .firstBoot, .verifying, .failed: return .setup
        case .idle, .sealed: return goldenAvailable ? .createVM : .setup
        }
    }
}

extension VMTabScreen {
    /// The Paused status bar's first detail: how long ago the state was saved.
    static func pausedAge(savedAt: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(savedAt) / 60))
        return switch minutes {
        case 0: "saved just now"
        case ..<60: "saved \(minutes) min ago"
        case ..<(24 * 60): "saved \(minutes / 60) h ago"
        default: "saved \(minutes / (24 * 60)) d ago"
        }
    }
}

/// What a running VM tab's status bar says about who drives the VM, and its main action.
struct VMDriverStatus: Equatable {
    enum Action: Equatable {
        case takeOver
        case handBack
    }

    let tone: VMStatusTone
    let title: String
    let details: [String]
    let action: Action

    /// `agentName` names the session of an `.agent` driver; `now` dates its last call.
    static func make(driver: VMDriver, agentName: String, now: Date) -> VMDriverStatus {
        switch driver {
        case .idle:
            VMDriverStatus(tone: .running, title: "Running", details: [], action: .takeOver)
        case .agent(_, let tool, let at):
            VMDriverStatus(
                tone: .running, title: "\(agentName) is driving",
                details: ["\(tool) \(max(0, Int(now.timeIntervalSince(at))))s ago"], action: .takeOver
            )
        case .user:
            VMDriverStatus(tone: .busy, title: "You're driving", details: ["agent calls are on hold"], action: .handBack)
        }
    }
}
