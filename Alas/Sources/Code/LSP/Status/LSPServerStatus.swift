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

    init(language: String, command: String, root: String, remoteHost: String?) {
        self.language = language
        self.command = command
        self.root = root
        self.remoteHost = remoteHost
    }

    /// A fresh process for this server is starting (spawn or restart).
    func reset() {
        initialized = false
        tasks = []
        set(.starting)
    }

    func markInitialized() {
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
        var detail = crashDetail ?? CrashDetail()
        detail.exitCode = exit.exitCode
        detail.uptime = exit.uptime
        detail.outputTail = exit.outputTail
        set(.crashed(detail))
    }

    func recordInitializeFailure(_ message: String) {
        var detail = crashDetail ?? CrashDetail()
        detail.initializeError = message
        set(.crashed(detail))
    }

    private var crashDetail: CrashDetail? {
        if case .crashed(let detail) = phase { return detail }
        return nil
    }

    private func set(_ newPhase: Phase) {
        if phase != newPhase { phase = newPhase }
    }
}
