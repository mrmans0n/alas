import Foundation

enum LSPPillGlyph: Equatable {
    case ready
    case loading
    case problem
    case none
}

enum LSPProblemReason: Equatable, Sendable {
    case notInstalled
    case disabled
    case blockedByGatekeeper
    case crashed

    var text: String {
        switch self {
        case .notInstalled: "not installed"
        case .disabled: "disabled"
        case .blockedByGatekeeper: "blocked by Gatekeeper"
        case .crashed: "crashed"
        }
    }
}

extension LSPServerUnavailableReason {
    var problemReason: LSPProblemReason {
        switch self {
        case .notInstalled: .notInstalled
        case .disabled: .disabled
        case .blockedByGatekeeper: .blockedByGatekeeper
        }
    }

    var explanation: String {
        switch self {
        case .notInstalled: "Language server not installed."
        case .disabled: "Disabled in settings."
        case .blockedByGatekeeper: "Blocked by Gatekeeper. Open the file in the editor to allow it."
        }
    }
}

/// What a status pill shows, independent of where the state came from.
enum LSPBadgeState: Equatable {
    case starting(language: String)
    case indexing(language: String, percentage: Int?, tooltip: String)
    case ready(language: String, command: String)
    case problem(language: String, reason: LSPProblemReason)
    case noLanguage(fileExtension: String)

    /// The editor badge: holder-derived status refined by the live server phase.
    static func make(editor: EditorLSPStatus, phase: LSPServerStatus.Phase?) -> LSPBadgeState {
        editor.refined(by: phase).badgeState
    }

    var glyph: LSPPillGlyph {
        switch self {
        case .starting, .indexing: .loading
        case .ready: .ready
        case .problem: .problem
        case .noLanguage: .none
        }
    }

    var label: String {
        switch self {
        case .starting(let language), .ready(let language, _), .problem(let language, _):
            language
        case .indexing(let language, let percentage, _):
            percentage.map { "\(language) \($0)%" } ?? language
        case .noLanguage(let ext):
            ext.isEmpty ? "Plain text" : ".\(ext)"
        }
    }

    var tooltip: String {
        switch self {
        case .starting(let language): "\(language) · starting…"
        case .indexing(_, _, let tooltip): tooltip
        case .ready(let language, let command): "\(language) · \(command)"
        case .problem(let language, let reason): "\(language) · \(reason.text)"
        case .noLanguage: "No language server"
        }
    }

    var isProblem: Bool {
        if case .problem = self { return true }
        return false
    }
}

enum LSPProgressSummary {
    /// The least-advanced reported percentage; `nil` when no task reports one.
    static func percentage(_ tasks: [LSPClient.ProgressTask]) -> Int? {
        tasks.compactMap(\.percentage).min()
    }

    /// `"<command> · <title> <message>"` for the earliest-begun task.
    static func tooltip(command: String, tasks: [LSPClient.ProgressTask]) -> String {
        guard let first = tasks.first else { return command }
        return ["\(command) ·", first.title, first.message].compactMap { $0 }.joined(separator: " ")
    }
}

enum LSPCrashSummary {
    static func headline(_ detail: LSPServerStatus.CrashDetail) -> String {
        let after = detail.uptime.map {
            " after \($0.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))"
        } ?? ""
        switch detail.termination {
        case .exit(let code): return "Exited with code \(code)\(after)."
        case .signal(let signal): return "Terminated by \(signalName(signal))\(after)."
        case nil: break
        }
        if let error = detail.initializeError { return "Failed to start: \(error)" }
        return "Connection closed\(after)."
    }

    private static func signalName(_ signal: Int32) -> String {
        let name: String? = switch signal {
        case SIGHUP: "SIGHUP"
        case SIGINT: "SIGINT"
        case SIGABRT: "SIGABRT"
        case SIGBUS: "SIGBUS"
        case SIGFPE: "SIGFPE"
        case SIGILL: "SIGILL"
        case SIGKILL: "SIGKILL"
        case SIGPIPE: "SIGPIPE"
        case SIGSEGV: "SIGSEGV"
        case SIGTERM: "SIGTERM"
        case SIGTRAP: "SIGTRAP"
        default: nil
        }
        return name.map { "signal \(signal) (\($0))" } ?? "signal \(signal)"
    }
}
