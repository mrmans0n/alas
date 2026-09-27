import Foundation
import Observation

@MainActor
@Observable
final class RunFailureBriefCoordinator {
    typealias Generate = @MainActor @Sendable (RunFailureBriefInput) async -> RunFailureBrief?

    enum State: Equatable, Sendable {
        case generating(FailureLogExcerpt)
        case ready(FailureLogExcerpt, RunFailureBrief)
        case unavailable(FailureLogExcerpt?)

        var excerpt: FailureLogExcerpt? {
            switch self {
            case let .generating(excerpt), let .ready(excerpt, _): excerpt
            case let .unavailable(excerpt): excerpt
            }
        }
    }

    private struct Owner {
        let worktreeID: String
        let scriptKey: String
    }

    private var states: [String: State] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var owners: [String: Owner] = [:]

    func state(for runID: String) -> State? {
        states[runID]
    }

    func start(
        _ failure: RunScriptFailure,
        loadOutput: @escaping @MainActor @Sendable () async -> String?,
        generate: Generate?
    ) {
        cancelInFlight(worktreeID: failure.worktreeID, scriptKey: failure.scriptKey)
        let runID = failure.runID
        owners[runID] = Owner(worktreeID: failure.worktreeID, scriptKey: failure.scriptKey)
        tasks[runID] = Task { [weak self] in
            let output = await loadOutput()
            guard !Task.isCancelled else { return }
            let excerpt: FailureLogExcerpt? = if let output {
                await Task.detached(priority: .utility) { FailureLogSelection.select(output) }.value
            } else {
                nil
            }
            guard let self, !Task.isCancelled else { return }
            guard let excerpt, let generate else {
                self.states[runID] = .unavailable(excerpt)
                return
            }
            self.states[runID] = .generating(excerpt)
            let brief = await generate(RunFailureBriefInput(
                scriptName: failure.scriptName,
                exitCode: failure.exitCode,
                excerpt: excerpt
            ))
            guard !Task.isCancelled, case .generating = self.states[runID] else { return }
            self.states[runID] = brief.map { .ready(excerpt, $0) } ?? .unavailable(excerpt)
        }
    }

    /// New output from the same script supersedes a brief that is still being written.
    func cancelInFlight(worktreeID: String, scriptKey: String) {
        for (runID, owner) in owners where owner.worktreeID == worktreeID && owner.scriptKey == scriptKey {
            if case .ready = states[runID] { continue }
            tasks[runID]?.cancel()
            states[runID] = .unavailable(states[runID]?.excerpt)
        }
    }

    /// Drops briefs whose failure is no longer queued (dismissed, retired, evicted, or purged).
    func retain(runIDs: Set<String>) {
        for runID in owners.keys where !runIDs.contains(runID) {
            tasks.removeValue(forKey: runID)?.cancel()
            owners.removeValue(forKey: runID)
            states.removeValue(forKey: runID)
        }
    }

    func invalidateAll() {
        retain(runIDs: [])
    }

    func awaitSettled(runID: String) async {
        await tasks[runID]?.value
    }
}
