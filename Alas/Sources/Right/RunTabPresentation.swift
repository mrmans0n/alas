import Foundation

enum RunStatusTone: Equatable {
    case idle
    case active
    case success
    case failure
    case warning
}

/// One action offered by a Run row. Modelled as data so the rules about which
/// actions a state allows are testable without touching SwiftUI.
enum RunRowAction: Hashable {
    /// "Run" the first time, "Rerun" once the script has an outcome.
    case start(label: String)
    case stop
    case restart
    case openTerminal
    case openEndpoint(URL)
    case showReport(runID: String)
    case edit
}

struct RunRowInput {
    let script: RunScript
    let record: RunRecord?
    /// A live terminal tab for this script exists in this worktree. An open
    /// shell is not evidence the command is still running — it only decides
    /// whether "jump to terminal" has anywhere to go.
    let hasTerminal: Bool
    let hasReport: Bool
    let target: RunExecutionTarget
    /// A peer's scripts live on the host, so they cannot be edited from here.
    var isEditable: Bool = true
}

struct RunRowPresentation: Equatable, Identifiable {
    let id: String
    let name: String
    let scope: RunScriptScope
    let statusLabel: String
    let tone: RunStatusTone
    let isActive: Bool
    /// "exit 42 · 12s · 3m ago". Nil until the script has been run.
    let detail: String?
    /// Compact execution context, nil when it's the plain local worktree root.
    let locationLabel: String?
    /// Always-complete host and working directory, for the row's tooltip.
    let locationDetail: String
    let conflictLabel: String?
    let actions: [RunRowAction]
}

enum RunTabPresentation {
    static func rows(_ inputs: [RunRowInput], now: Date) -> [RunRowPresentation] {
        inputs.map { row($0, now: now) }
    }

    /// `hostLabel` names the machine when the target has no host of its own,
    /// as a peer's runs do: they are local to the host, not to this Mac.
    static func row(_ input: RunRowInput, now: Date, hostLabel: String? = nil) -> RunRowPresentation {
        let status = input.record?.status ?? .notRun
        return RunRowPresentation(
            id: input.script.key,
            name: input.script.displayName,
            scope: input.script.scope,
            statusLabel: statusLabel(status),
            tone: tone(status),
            isActive: status.isActive,
            detail: detail(record: input.record, now: now),
            locationLabel: locationLabel(script: input.script, target: input.target),
            locationDetail: locationDetail(target: input.target, hostLabel: hostLabel),
            conflictLabel: input.record?.portConflict.map(conflictLabel),
            actions: actions(input: input, status: status)
        )
    }

    /// A peer's row follows the local rules, without a script to edit. Its
    /// terminal is the run's console, when the host lists it in `consoleIds`.
    static func peerRow(
        _ row: PeerRuns.Row, hostName: String, consoleIds: Set<String>, now: Date
    ) -> RunRowPresentation {
        let script = RunScript(
            scope: row.script.scope,
            fileName: row.script.fileName,
            // Never read: the script file lives on the host.
            fileURL: URL(fileURLWithPath: row.script.fileName),
            displayName: row.script.name,
            onExit: .keep,
            cwd: row.script.cwd,
            isExecutable: true
        )
        let hasReport = if case .finished = row.record?.status { true } else { false }
        let input = RunRowInput(
            script: script,
            record: row.record,
            hasTerminal: row.record?.sessionID.map(consoleIds.contains) ?? false,
            hasReport: hasReport,
            target: row.record?.target ?? row.script.target,
            isEditable: false
        )
        return self.row(input, now: now, hostLabel: hostName)
    }

    // MARK: - Status

    static func statusLabel(_ status: RunStatus) -> String {
        switch status {
        case .notRun:                     "Not run"
        case .starting:                   "Starting"
        case .running:                    "Running"
        case .finished(.succeeded):       "Succeeded"
        case .finished(.failed):          "Failed"
        case .finished(.stopped):         "Stopped"
        case .finished(.unknown):         "Unknown"
        }
    }

    static func tone(_ status: RunStatus) -> RunStatusTone {
        switch status {
        case .notRun:                     .idle
        case .starting, .running:         .active
        case .finished(.succeeded):       .success
        case .finished(.failed):          .failure
        case .finished(.stopped):         .warning
        case .finished(.unknown):         .warning
        }
    }

    // MARK: - Detail

    private static func detail(record: RunRecord?, now: Date) -> String? {
        guard let record else { return nil }
        switch record.status {
        case .notRun:
            return nil
        case .starting:
            return "Launching terminal"
        case .running:
            return "Started \(relative(from: record.startedAt, to: now))"
        case .finished(let outcome):
            var parts: [String] = []
            switch outcome {
            case .succeeded:
                break
            case .failed(let exitCode):
                parts.append("exit \(exitCode)")
            case .stopped:
                parts.append("stopped before it finished")
            case .unknown:
                // Never claim an outcome we did not observe.
                parts.append("no exit status observed")
            }
            if let duration = record.duration {
                parts.append(format(duration: duration))
            }
            if let finishedAt = record.finishedAt {
                parts.append(relative(from: finishedAt, to: now))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    static func format(duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        guard total >= 60 else { return "\(max(0, total))s" }
        let minutes = total / 60
        guard minutes >= 60 else { return "\(minutes)m \(total % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func relative(from date: Date, to now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded())
        guard seconds >= 60 else { return "just now" }
        let minutes = seconds / 60
        guard minutes >= 60 else { return "\(minutes)m ago" }
        let hours = minutes / 60
        guard hours >= 24 else { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    static func historyDetail(_ entry: RunHistorySummary, now: Date) -> String {
        let outcome = switch entry.outcome {
        case .succeeded: "Succeeded"
        case let .failed(exitCode): "Failed · exit \(exitCode)"
        case .stopped: "Stopped"
        case .unknown: "Unknown"
        }
        return [
            outcome,
            format(duration: entry.duration),
            entry.branch,
            relative(from: entry.finishedAt, to: now),
        ].joined(separator: " · ")
    }

    // MARK: - Location

    private static func locationLabel(script: RunScript, target: RunExecutionTarget) -> String? {
        let cwd = script.cwd?.trimmingCharacters(in: .whitespaces)
        let subdirectory = (cwd?.isEmpty == false && cwd != ".") ? cwd : nil
        switch (target.host, subdirectory) {
        case (nil, nil):                       return nil
        case (nil, let subdirectory?):         return subdirectory
        case (let host?, nil):                 return host
        case (let host?, let subdirectory?):   return "\(host) · \(subdirectory)"
        }
    }

    private static func locationDetail(target: RunExecutionTarget, hostLabel: String?) -> String {
        "\(target.host ?? hostLabel ?? target.hostLabel) · \(target.workingDirectory)"
    }

    static func conflictLabel(_ conflict: RunPortConflict) -> String {
        switch conflict {
        case let .ownedByRun(_, branch, scriptName):
            return "Port already served by \(scriptName) on \(branch)"
        case .externalProcess:
            return "Port already in use by another process"
        }
    }

    // MARK: - Actions

    private static func actions(input: RunRowInput, status: RunStatus) -> [RunRowAction] {
        var actions: [RunRowAction] = []
        if status.isActive {
            actions.append(.stop)
            actions.append(.restart)
            // The endpoint only appears once the command is actually up;
            // offering it mid-launch would just hand the user a dead link.
            if status == .running, let endpoint = input.script.endpoint {
                actions.append(.openEndpoint(endpoint))
            }
        } else {
            let hasOutcome = if case .finished = status { true } else { false }
            actions.append(.start(label: hasOutcome ? "Rerun" : "Run"))
            if hasOutcome, input.hasReport, let runID = input.record?.id {
                actions.append(.showReport(runID: runID))
            }
        }
        if input.hasTerminal {
            actions.append(.openTerminal)
        }
        if input.isEditable {
            actions.append(.edit)
        }
        return actions
    }
}
