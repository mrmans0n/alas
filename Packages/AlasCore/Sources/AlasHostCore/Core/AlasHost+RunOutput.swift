import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

/// What a finished run printed, as the host serves it.
public enum HostRunOutput: Codable, Equatable, Sendable {
    case unknownRun
    case notFinished
    /// The run finished but its output was not kept.
    case unavailable
    /// What it printed; `truncated` when only the tail past the history's
    /// size limit was kept.
    case text(String, truncated: Bool)

    /// As plugins read it, without the truncation flag their API lacks.
    public var plugin: PluginRunOutput {
        switch self {
        case .unknownRun: .unknownRun
        case .notFinished: .notFinished
        case .unavailable: .unavailable
        case .text(let text, _): .text(text)
        }
    }
}

extension RunsAPI {
    /// What run `runID` printed, once it finished, if it ran in a worktree of
    /// `projectID`.
    public func output(of runID: String, projectID: String) async -> HostRunOutput {
        let worktreeIDs = Set(core.projects.worktrees(projectId: projectID).map(\.id))
        for worktreeID in worktreeIDs where core.runRecords.records(worktreeID: worktreeID).first(where: { $0.id == runID })?.status.isActive == true {
            return .notFinished
        }
        // A run that just finished may still be on its way to the history
        // store, even one a newer run of the same script has since replaced
        // in the records.
        for worktreeID in worktreeIDs { await core.runHistory.flush(worktreeID: worktreeID) }
        let entry: RunHistoryEntry? = if let transient = worktreeIDs.lazy.compactMap({ core.runHistory.transientReport(worktreeID: $0, runID: runID) }).first {
            transient
        } else {
            try? await core.runHistory.store?.entry(id: runID)
        }
        guard let entry, worktreeIDs.contains(entry.worktreeID) else { return .unknownRun }
        return switch entry.output {
        case .available(let text, let truncated): .text(text, truncated: truncated)
        case .unavailable: .unavailable
        }
    }

    /// Starts script `scriptKey` in `worktree`, or restarts it when its last
    /// run finished or its console is still open, so no second console
    /// opens. Returns why it did not, or nil once it is starting.
    public func startOrRestart(scriptKey: String, in worktree: Worktree, caller: HostCaller) async -> String? {
        caller.log("runs.startOrRestart", scriptKey)
        let remoteHost = RemoteHostRegistry.shared.host(forPath: worktree.path.path)
        switch await RunScriptStore.discoverScripts(worktreeRoot: worktree.path, remoteHost: remoteHost) {
        case .failed(let message):
            return message
        case .scripts(let scripts):
            guard let script = scripts.first(where: { $0.key == scriptKey }) else { return "unknown run script \(scriptKey)" }
            let record = core.runRecords.record(worktreeID: worktree.id, scriptKey: script.key)
            if record?.status.isActive == true { return "\(script.key) is already running" }
            let console = core.environment.runConsoleIsHidden(scriptKey: script.key, worktreeID: worktree.id)
            let result: RunStart
            if case .finished? = record?.status {
                result = restart(script, in: worktree, isHidden: (console ?? (script.console == .hidden)), caller: caller)
            } else if let console {
                result = restart(script, in: worktree, isHidden: console, caller: caller)
            } else {
                result = start(script, in: worktree, isHidden: script.console == .hidden, caller: caller)
            }
            return switch result {
            case .started, .alreadyStarting: nil
            case .projectUnavailable: "the project is unavailable"
            case let .refused(title, message): "\(title): \(message)"
            }
        }
    }
}
