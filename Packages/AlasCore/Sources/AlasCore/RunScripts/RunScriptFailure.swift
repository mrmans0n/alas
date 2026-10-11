import Foundation

/// Short-lived metadata for failure banners and attention. Durable output lives
/// exclusively in `RunHistoryStore`, keyed by `runID`.
public struct RunScriptFailure: Identifiable, Equatable, Sendable {
    public let id: String
    public let runID: String
    public let scriptKey: String
    public let scriptName: String
    public let worktreeID: String
    public let branch: String
    public let exitCode: Int32
    public let completedAt: Date

    public init(id: String, runID: String, scriptKey: String, scriptName: String, worktreeID: String, branch: String, exitCode: Int32, completedAt: Date) {
        self.id = id
        self.runID = runID
        self.scriptKey = scriptKey
        self.scriptName = scriptName
        self.worktreeID = worktreeID
        self.branch = branch
        self.exitCode = exitCode
        self.completedAt = completedAt
    }
}

public struct RunScriptFailureQueue: Equatable, Sendable {
    public private(set) var byWorktree: [String: [RunScriptFailure]] = [:]

    public mutating func append(_ failure: RunScriptFailure) {
        byWorktree[failure.worktreeID, default: []].insert(failure, at: 0)
        byWorktree[failure.worktreeID]!.sort { $0.completedAt > $1.completedAt }
        byWorktree[failure.worktreeID] = Array(byWorktree[failure.worktreeID]!.prefix(3))
    }

    public var runIDs: Set<String> {
        Set(byWorktree.values.joined().map(\.runID))
    }

    public func failures(for worktreeID: String) -> [RunScriptFailure] {
        byWorktree[worktreeID, default: []]
    }

    public mutating func dismiss(id: String, worktreeID: String) {
        guard var failures = byWorktree[worktreeID] else { return }
        failures.removeAll { $0.id == id }
        byWorktree[worktreeID] = failures.isEmpty ? nil : failures
    }

    public mutating func purge(worktreeID: String) {
        byWorktree[worktreeID] = nil
    }

    public init(byWorktree: [String: [RunScriptFailure]] = [:]) {
        self.byWorktree = byWorktree
    }
}
