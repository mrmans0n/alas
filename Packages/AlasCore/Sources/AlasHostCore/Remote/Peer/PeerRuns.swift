import Foundation
import AlasFeatures

/// A paired host's Run tab: its listed scripts joined with the channel's run
/// records, and each row action sent as one host request.
public enum PeerRuns {
    public struct Row: Equatable, Sendable {
        public var script: HostRunScript
        public var record: RunRecord?

        public init(script: HostRunScript, record: RunRecord?) {
            self.script = script
            self.record = record
        }
    }

    public enum Command: Equatable, Sendable {
        case start, stop, restart
        case output(runID: String)
    }

    public enum Reply: Equatable, Sendable {
        case done
        case refused(title: String, message: String)
        case output(RunReportOutputPresentation)
    }

    /// The listed scripts in order, then active runs of `worktreeID` the
    /// listing lacks, as the local Run tab shows them. `scripts` is nil when
    /// the listing failed, which leaves only those active runs.
    public static func rows(scripts: [HostRunScript]?, runs: [RunRecord], worktreeID: String) -> [Row] {
        let records = runs.filter { $0.worktreeID == worktreeID }
        let recordsByKey = Dictionary(records.map { ($0.scriptKey, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = scripts ?? []
        let listedKeys = Set(listed.map(\.key))
        let unlisted = records
            .filter { $0.status.isActive && !listedKeys.contains($0.scriptKey) }
            .compactMap { record -> Row? in
                let parts = record.scriptKey.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let scope = RunScriptScope(rawValue: String(parts[0])) else { return nil }
                let script = HostRunScript(
                    scope: scope, fileName: String(parts[1]), name: record.scriptName, cwd: nil, target: record.target
                )
                return Row(script: script, record: record)
            }
            .sorted {
                if $0.script.scope != $1.script.scope { return $0.script.scope.rawValue < $1.script.scope.rawValue }
                return $0.script.name.localizedStandardCompare($1.script.name) == .orderedAscending
            }
        return listed.map { Row(script: $0, record: recordsByKey[$0.key]) } + unlisted
    }

    public static func perform(
        _ command: Command, on row: Row, in worktree: WorktreeRef,
        request: (HostRequest) async -> HostResponse
    ) async -> Reply {
        let key = row.script.key
        let title = if case .output = command { "Run Output" } else { "Run Script Failed" }
        let hostRequest: HostRequest = switch command {
        // Rerun replaces the kept console, as `RunsAPI.startOrRestart` does.
        // ponytail: Rerun races a run started elsewhere since the last event and restarts it; send the seen run id if that bites.
        case .start:
            if case .finished = row.record?.status {
                .restartRun(scriptKey: key, worktree: worktree)
            } else {
                .startRun(scriptKey: key, worktree: worktree)
            }
        case .restart: .restartRun(scriptKey: key, worktree: worktree)
        case .stop: .stopRun(scriptKey: key, worktree: worktree)
        case .output(let runID): .runOutput(runID: runID, projectID: worktree.projectID)
        }
        switch await request(hostRequest) {
        case .done, .runStart(.started), .runStart(.alreadyStarting): return .done
        case .runStart(.refused(let title, let message)): return .refused(title: title, message: message)
        case .runStart(.projectUnavailable):
            return .refused(title: title, message: "The project is no longer available on the host.")
        case .runOutput(.text(let text, let truncated)):
            return .output(.make(for: .available(text: text, truncated: truncated)))
        case .runOutput(.unavailable): return .output(.unavailable)
        case .runOutput(.notFinished): return .refused(title: title, message: "This run has not finished yet.")
        case .runOutput(.unknownRun): return .refused(title: title, message: "The host no longer has this run's output.")
        // The shared message names a worktree.
        case .failure(.notFound(let what)): return .refused(title: title, message: "The host has no \(what).")
        case .failure(let error): return .refused(title: title, message: PeerWorktreeRemoval.message(for: error))
        default: return .refused(title: title, message: "The host sent an unexpected reply.")
        }
    }
}
