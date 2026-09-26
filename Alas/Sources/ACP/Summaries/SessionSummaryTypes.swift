import Foundation

struct SessionSummaryTurn: Equatable, Sendable {
    let user: String
    let assistant: String
}

struct SessionSummarySourceRevision: Equatable, Sendable {
    let incarnation: UUID
    let promptID: Int
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

extension SessionSummarySourceRevision {
    @MainActor
    static func current(session: ACPSession, composer: ACPComposerState) -> Self {
        .init(
            incarnation: session.incarnation,
            promptID: session.nextPromptID,
            transcriptGeneration: session.transcript.messagesGeneration,
            goal: session.currentGoal,
            plan: session.transcript.currentPlan,
            idleFacts: .current(session: session, composer: composer)
        )
    }
}

extension SessionSummaryIdleFacts {
    @MainActor
    static func current(session: ACPSession, composer: ACPComposerState) -> Self {
        let transcript = session.transcript
        return .init(
            agentReady: session.agentState == .ready,
            hydrationReady: session.hydrationState == .ready,
            streamingIsIdle: transcript.streamingState == .idle,
            composerIsEmpty: composer.draft.isEmpty,
            queuedPromptCount: session.queue.count,
            pendingQueuePersistenceCount: session.pendingQueuePersistenceCount,
            pendingPermission: transcript.pendingPermission != nil,
            pendingQuestion: transcript.pendingQuestion != nil,
            pendingPlan: transcript.pendingPlan != nil,
            pendingUserInputCount: transcript.pendingUserInputs.count,
            urlElicitationCount: transcript.urlElicitationWaits.count,
            pendingWorkCount: session.nextPromptWorkCount,
            hasPendingDelegatedMessages: session.hasPendingDelegatedMessages,
            hasRunningSubagent: session.subagents.values.contains(where: \.isRunning),
            retrying: session.retryStatus != nil,
            recovering: session.connectionRecoveryState != nil
                || session.contextRestoreWarning != nil
                || (session.contextRecoveryStatus != nil && session.contextRecoveryStatus != .restored)
                || session.forkRecord?.phase == .negotiatingNative
                || session.forkRecord?.contextDeliveryPending == true,
            autoRunEnabled: session.autoRunEnabled
        )
    }
}

struct SessionSummary: Equatable, Sendable {
    let goal: String?
    let completed: [String]
    let blockers: [String]
    let nextAction: String?
    let isPartial: Bool
}
