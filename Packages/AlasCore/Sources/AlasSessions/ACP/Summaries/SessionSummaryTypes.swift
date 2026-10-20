import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

public struct SessionSummarySourceRevision: Equatable, Sendable {
    public let incarnation: UUID
    public let promptID: Int
    public let transcriptGeneration: UInt64
    public let goal: ACPGoalState?
    public let plan: [ACPMessage.PlanItem]?
    public let idleFacts: SessionSummaryIdleFacts

    public init(incarnation: UUID, promptID: Int, transcriptGeneration: UInt64, goal: ACPGoalState?, plan: [ACPMessage.PlanItem]?, idleFacts: SessionSummaryIdleFacts) {
        self.incarnation = incarnation
        self.promptID = promptID
        self.transcriptGeneration = transcriptGeneration
        self.goal = goal
        self.plan = plan
        self.idleFacts = idleFacts
    }
}

public struct SessionSummaryIdleFacts: Equatable, Sendable {
    public let agentReady: Bool
    public let hydrationReady: Bool
    public let streamingIsIdle: Bool
    public let composerIsEmpty: Bool
    public let queuedPromptCount: Int
    public let pendingQueuePersistenceCount: Int
    public let pendingPermission: Bool
    public let pendingQuestion: Bool
    public let pendingPlan: Bool
    public let pendingUserInputCount: Int
    public let urlElicitationCount: Int
    public let pendingWorkCount: Int
    public let hasPendingDelegatedMessages: Bool
    public let hasRunningSubagent: Bool
    public let retrying: Bool
    public let recovering: Bool
    /// Part of the source revision so toggling it stales a summary, but not an
    /// idle blocker: an auto-run session with no turn in flight is idle.
    public let autoRunEnabled: Bool

    public var isIdle: Bool {
        agentReady && hydrationReady && streamingIsIdle && composerIsEmpty
            && queuedPromptCount == 0 && pendingQueuePersistenceCount == 0
            && !pendingPermission && !pendingQuestion
            && !pendingPlan && pendingUserInputCount == 0 && urlElicitationCount == 0
            && pendingWorkCount == 0 && !hasPendingDelegatedMessages && !hasRunningSubagent && !retrying
            && !recovering
    }

    public init(agentReady: Bool, hydrationReady: Bool, streamingIsIdle: Bool, composerIsEmpty: Bool, queuedPromptCount: Int, pendingQueuePersistenceCount: Int, pendingPermission: Bool, pendingQuestion: Bool, pendingPlan: Bool, pendingUserInputCount: Int, urlElicitationCount: Int, pendingWorkCount: Int, hasPendingDelegatedMessages: Bool, hasRunningSubagent: Bool, retrying: Bool, recovering: Bool, autoRunEnabled: Bool) {
        self.agentReady = agentReady
        self.hydrationReady = hydrationReady
        self.streamingIsIdle = streamingIsIdle
        self.composerIsEmpty = composerIsEmpty
        self.queuedPromptCount = queuedPromptCount
        self.pendingQueuePersistenceCount = pendingQueuePersistenceCount
        self.pendingPermission = pendingPermission
        self.pendingQuestion = pendingQuestion
        self.pendingPlan = pendingPlan
        self.pendingUserInputCount = pendingUserInputCount
        self.urlElicitationCount = urlElicitationCount
        self.pendingWorkCount = pendingWorkCount
        self.hasPendingDelegatedMessages = hasPendingDelegatedMessages
        self.hasRunningSubagent = hasRunningSubagent
        self.retrying = retrying
        self.recovering = recovering
        self.autoRunEnabled = autoRunEnabled
    }
}

extension SessionSummarySourceRevision {
    @MainActor
    public static func current(session: ACPSession, composer: ACPComposerState) -> Self {
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
    public static func current(session: ACPSession, composer: ACPComposerState) -> Self {
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
