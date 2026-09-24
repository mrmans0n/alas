import Foundation

/// Short-lived metadata for failure banners and attention. Durable output lives
/// exclusively in `RunHistoryStore`, keyed by `runID`.
struct RunScriptFailure: Identifiable, Equatable, Sendable {
    let id: String
    let runID: String
    let scriptKey: String
    let scriptName: String
    let worktreeID: String
    let projectId: String?
    let branch: String
    let exitCode: Int32
    let completedAt: Date

    init(
        id: String,
        runID: String,
        scriptKey: String,
        scriptName: String,
        worktreeID: String,
        projectId: String? = nil,
        branch: String,
        exitCode: Int32,
        completedAt: Date
    ) {
        self.id = id
        self.runID = runID
        self.scriptKey = scriptKey
        self.scriptName = scriptName
        self.worktreeID = worktreeID
        self.projectId = projectId
        self.branch = branch
        self.exitCode = exitCode
        self.completedAt = completedAt
    }
}

struct RunScriptFailureQueue: Equatable {
    private(set) var byWorktree: [String: [RunScriptFailure]] = [:]

    mutating func append(_ failure: RunScriptFailure) {
        let existing = byWorktree[failure.worktreeID, default: []]
        var projectFailures = existing.filter { $0.projectId == failure.projectId }
        projectFailures.insert(failure, at: 0)
        projectFailures.sort { $0.completedAt > $1.completedAt }

        let otherProjectFailures = existing.filter { $0.projectId != failure.projectId }
        byWorktree[failure.worktreeID] = (otherProjectFailures + Array(projectFailures.prefix(3)))
            .sorted { $0.completedAt > $1.completedAt }
    }

    func failures(for worktreeID: String, projectId: String? = nil) -> [RunScriptFailure] {
        let failures = byWorktree[worktreeID, default: []]
        guard let projectId else { return failures }
        return failures.filter { $0.projectId == projectId }
    }

    mutating func dismiss(id: String, worktreeID: String, projectId: String? = nil) {
        guard var failures = byWorktree[worktreeID] else { return }
        failures.removeAll { failure in
            failure.id == id && (projectId == nil || failure.projectId == projectId)
        }
        byWorktree[worktreeID] = failures.isEmpty ? nil : failures
    }

    mutating func purge(worktreeID: String, projectId: String? = nil) {
        guard let projectId else {
            byWorktree[worktreeID] = nil
            return
        }
        guard var failures = byWorktree[worktreeID] else { return }
        failures.removeAll { $0.projectId == projectId }
        byWorktree[worktreeID] = failures.isEmpty ? nil : failures
    }
}
