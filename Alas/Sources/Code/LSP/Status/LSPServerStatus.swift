import Foundation
import Observation

/// Observable state of one language server process, shared by every pane that
/// shows it. Owned by `WorkspaceLSPManager`; the same object survives restarts
/// of its server so views holding it keep updating.
@Observable
@MainActor
final class LSPServerStatus {
    enum Phase: Equatable, Sendable {
        case starting
        case indexing([LSPClient.ProgressTask])
        case ready
        case crashed(CrashDetail)
    }

    struct CrashDetail: Equatable, Sendable {
        var exitCode: Int32?
        var uptime: Duration?
        var outputTail: [String] = []
        var initializeError: String?
    }

    nonisolated let id = UUID()
    let language: String
    let command: String
    let root: String
    let remoteHost: String?
    private(set) var phase: Phase = .starting

    @ObservationIgnored private var initialized = false
    @ObservationIgnored private var tasks: [LSPClient.ProgressTask] = []
    /// `initialize` has either succeeded or failed. Exit and failure reports
    /// that arrive before that are held so a server dying mid-initialize
    /// publishes one crash carrying both, not a partial one that is rewritten.
    @ObservationIgnored private var initializeResolved = false
    @ObservationIgnored private var pendingExit: LSPClient.ExitDetail?
    @ObservationIgnored private var pendingInitializeError: String?

    init(language: String, command: String, root: String, remoteHost: String?) {
        self.language = language
        self.command = command
        self.root = root
        self.remoteHost = remoteHost
    }

    /// A fresh process for this server is starting (spawn or restart).
    func reset() {
        initialized = false
        initializeResolved = false
        pendingExit = nil
        pendingInitializeError = nil
        tasks = []
        set(.starting)
    }

    func markInitialized() {
        initializeResolved = true
        if let exit = pendingExit {
            // The process exited between the initialize reply and this hop.
            pendingExit = nil
            publishCrash(exit: exit, initializeError: nil)
            return
        }
        initialized = true
        if case .crashed = phase { return }
        set(tasks.isEmpty ? .ready : .indexing(tasks))
    }

    /// Progress that arrives before `initialize` completes is held until then.
    func applyProgress(_ tasks: [LSPClient.ProgressTask]) {
        self.tasks = tasks
        guard initialized else { return }
        if case .crashed = phase { return }
        set(tasks.isEmpty ? .ready : .indexing(tasks))
    }

    func recordExit(_ exit: LSPClient.ExitDetail) {
        guard initializeResolved else {
            pendingExit = exit
            return
        }
        // An initialize failure that was waiting for this exit completes now.
        let error = pendingInitializeError
        pendingInitializeError = nil
        publishCrash(exit: exit, initializeError: error)
    }

    /// `exitExpected`: the failure was caused by the server process ending, so
    /// its exit report follows (or already arrived) and the crash is published
    /// once that report merges in.
    func recordInitializeFailure(_ message: String, exitExpected: Bool = false) {
        initializeResolved = true
        if let exit = pendingExit {
            pendingExit = nil
            publishCrash(exit: exit, initializeError: message)
        } else if exitExpected {
            pendingInitializeError = message
        } else {
            publishCrash(exit: nil, initializeError: message)
        }
    }

    private func publishCrash(exit: LSPClient.ExitDetail?, initializeError: String?) {
        var detail = CrashDetail()
        if case .crashed(let existing) = phase { detail = existing }
        if let exit {
            detail.exitCode = exit.exitCode
            detail.uptime = exit.uptime
            detail.outputTail = exit.outputTail
        }
        if let initializeError { detail.initializeError = initializeError }
        set(.crashed(detail))
    }

    private func set(_ newPhase: Phase) {
        if phase != newPhase { phase = newPhase }
    }
}
