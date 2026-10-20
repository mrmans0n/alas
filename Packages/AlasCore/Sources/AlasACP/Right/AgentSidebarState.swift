import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum AgentSidebarState: Equatable, Sendable {
    case running
    case awaitingInput
    case permissionRequest
    case idle
    /// The last turn failed; the session is stopped until the next prompt.
    case failed
    case detached
    case unknown
}

public struct AgentSidebarPlanProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let currentStep: String?

    public init(completed: Int, total: Int, currentStep: String?) {
        self.completed = completed
        self.total = total
        self.currentStep = currentStep
    }
}

/// One of a live session's own (native) subagents. These hang off their
/// parent row rather than being rows themselves, so counts and plugin
/// snapshots built from `AgentSidebarRollup.rows` keep meaning sessions.
public struct AgentSidebarSubagent: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let task: String?
    public let state: ACPSubagentState
    public let canCancel: Bool
    public let startedAt: Date
    public let finishedAt: Date?

    public init(id: String, name: String, task: String?, state: ACPSubagentState, canCancel: Bool, startedAt: Date, finishedAt: Date?) {
        self.id = id
        self.name = name
        self.task = task
        self.state = state
        self.canCancel = canCancel
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
