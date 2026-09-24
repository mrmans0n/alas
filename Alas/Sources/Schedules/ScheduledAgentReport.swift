import Foundation

enum ScheduledAgentReportLimits {
    static let maximumPayloadBytes = 256_000
    static let maximumTextBytes = 64_000
    static let maximumItems = 100
}

enum ScheduledAgentTaskState: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case needsAttention
    case interrupted
}

enum ScheduledAgentCleanupState: String, Codable, Sendable {
    case notRequested
    case pending
    case removed
    case retained
    case failed
}

struct ScheduledAgentReportRoute: Equatable, Sendable {
    let projectID: String
    let reportID: String
}

struct ScheduledAgentReportCheck: Codable, Equatable, Sendable {
    let name: String
    let result: String
}

struct ScheduledAgentReportLink: Codable, Equatable, Sendable {
    let label: String
    let url: String
}

struct ScheduledAgentCompletion: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case succeeded
        case failed
        case needsAttention = "needs_attention"
    }

    let outcome: Outcome
    let summary: String
    let checks: [ScheduledAgentReportCheck]
    let links: [ScheduledAgentReportLink]
}

@MainActor
final class ScheduledAgentRunRegistration {
    private enum CompletionState: Equatable {
        case accepting
        case writing
        case completed
        case closed
    }

    let reportID: String
    let occurrenceID: String
    let scheduleID: String
    let projectID: String
    let worktreeID: String
    let worktreeLineageID: String?
    let sessionID: String
    let promptID: UUID
    private(set) var completion: ScheduledAgentCompletion?
    private var completionState: CompletionState = .accepting

    var acceptsCompletion: Bool { completionState == .accepting }

    init(
        reportID: String,
        occurrenceID: String,
        scheduleID: String,
        projectID: String,
        worktreeID: String,
        worktreeLineageID: String? = nil,
        sessionID: String,
        promptID: UUID
    ) {
        self.reportID = reportID
        self.occurrenceID = occurrenceID
        self.scheduleID = scheduleID
        self.projectID = projectID
        self.worktreeID = worktreeID
        self.worktreeLineageID = worktreeLineageID
        self.sessionID = sessionID
        self.promptID = promptID
    }

    func reserveCompletion() -> Bool {
        guard completionState == .accepting else { return false }
        completionState = .writing
        return true
    }

    func recordPersistedCompletion(_ completion: ScheduledAgentCompletion) -> Bool {
        guard completionState == .writing else { return false }
        self.completion = completion
        completionState = .completed
        return true
    }

    func retryAfterPersistenceFailure() {
        guard completionState == .writing else { return }
        completionState = .accepting
    }

    func invalidate() {
        completionState = .closed
    }
}

/// Durable result for one target of a scheduled firing. It intentionally
/// survives both schedule-history pruning and worktree/session deletion.
struct ScheduledAgentReport: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let occurrenceID: String
    let scheduleID: String
    let scheduleName: String
    let projectID: String
    let projectName: String
    let branch: String?
    let baseCommit: String?
    let worktreeID: String?
    var sessionID: String?
    let agentID: String
    let modelID: String?
    let request: String
    var scriptRun: RunScheduleFiring.RunReference?
    let startedAt: Date
    var finishedAt: Date?
    var taskState: ScheduledAgentTaskState
    var completion: ScheduledAgentCompletion?
    let cleanupRequested: Bool
    var cleanupState: ScheduledAgentCleanupState
    var cleanupReason: String?

    init(
        id: String,
        occurrenceID: String,
        scheduleID: String,
        scheduleName: String,
        projectID: String,
        projectName: String,
        branch: String? = nil,
        baseCommit: String? = nil,
        worktreeID: String? = nil,
        sessionID: String? = nil,
        agentID: String,
        modelID: String? = nil,
        request: String,
        scriptRun: RunScheduleFiring.RunReference? = nil,
        startedAt: Date,
        finishedAt: Date? = nil,
        taskState: ScheduledAgentTaskState = .running,
        completion: ScheduledAgentCompletion? = nil,
        cleanupRequested: Bool = false,
        cleanupState: ScheduledAgentCleanupState = .notRequested,
        cleanupReason: String? = nil
    ) {
        self.id = id
        self.occurrenceID = occurrenceID
        self.scheduleID = scheduleID
        self.scheduleName = scheduleName
        self.projectID = projectID
        self.projectName = projectName
        self.branch = branch
        self.baseCommit = baseCommit
        self.worktreeID = worktreeID
        self.sessionID = sessionID
        self.agentID = agentID
        self.modelID = modelID
        self.request = request
        self.scriptRun = scriptRun
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.taskState = taskState
        self.completion = completion
        self.cleanupRequested = cleanupRequested
        self.cleanupState = cleanupState
        self.cleanupReason = cleanupReason
    }

    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }
}
