import Foundation

struct SessionSummaryTurn: Equatable, Sendable {
    let user: String
    let assistant: String
}

struct SessionSummarySourceRevision: Equatable, Sendable {
    let incarnation: UUID
    let transcriptGeneration: UInt64
    let goal: ACPGoalState?
    let plan: [ACPMessage.PlanItem]?
    let idleFacts: SessionSummaryIdleFacts
}

struct SessionSummaryIdleFacts: Equatable, Sendable {
    let agentReady: Bool
    let hydrationReady: Bool
    let streamingIsIdle: Bool
    let composerIsEmpty: Bool
    let queuedPromptCount: Int
    let pendingQueuePersistenceCount: Int
    let pendingPermission: Bool
    let pendingQuestion: Bool
    let pendingPlan: Bool
    let pendingUserInputCount: Int
    let urlElicitationCount: Int
    let pendingWorkCount: Int
    let hasPendingDelegatedMessages: Bool
    let hasRunningSubagent: Bool
    let retrying: Bool
    let recovering: Bool
    let autoRunEnabled: Bool

    var isIdle: Bool {
        agentReady && hydrationReady && streamingIsIdle && composerIsEmpty
            && queuedPromptCount == 0 && pendingQueuePersistenceCount == 0
            && !pendingPermission && !pendingQuestion
            && !pendingPlan && pendingUserInputCount == 0 && urlElicitationCount == 0
            && pendingWorkCount == 0 && !hasPendingDelegatedMessages && !hasRunningSubagent && !retrying
            && !recovering && !autoRunEnabled
    }
}

struct SessionSummary: Equatable, Sendable {
    let goal: String?
    let completed: [String]
    let blockers: [String]
    let nextAction: String?
    let isPartial: Bool
}
