import Foundation

enum RunScriptCapturedOutput: Equatable, Sendable {
    case available(text: String, truncated: Bool)
    case unavailable
}

struct RunScriptFailure: Identifiable, Equatable, Sendable {
    let id: String
    let runID: String
    let scriptKey: String
    let scriptName: String
    let worktreeID: String
    let branch: String
    let exitCode: Int32
    let completedAt: Date
    let capturedOutput: RunScriptCapturedOutput
}

struct RunScriptFailureQueue: Equatable {
    private(set) var byWorktree: [String: [RunScriptFailure]] = [:]

    mutating func append(_ failure: RunScriptFailure) {
        byWorktree[failure.worktreeID, default: []].insert(failure, at: 0)
        byWorktree[failure.worktreeID] = Array(byWorktree[failure.worktreeID]!.prefix(3))
    }

    func failures(for worktreeID: String) -> [RunScriptFailure] {
        byWorktree[worktreeID, default: []]
    }

    mutating func dismiss(id: String, worktreeID: String) {
        guard var failures = byWorktree[worktreeID] else { return }
        failures.removeAll { $0.id == id }
        byWorktree[worktreeID] = failures.isEmpty ? nil : failures
    }

    mutating func purge(worktreeID: String) {
        byWorktree[worktreeID] = nil
    }
}
