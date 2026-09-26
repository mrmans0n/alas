import Foundation

struct SessionSummaryContext: Equatable, Sendable {
    static let sourceLimit = 128 * 1024
    static let tokenLimit = 8_192

    let revision: SessionSummarySourceRevision
    let goal: ACPGoalState?
    let plan: [ACPMessage.PlanItem]
    let turns: [SessionSummaryTurn]
    let omittedOlderTurns: Bool

    @MainActor
    static func snapshot(session: ACPSession) -> SessionSummaryContext? {
        let allTurns = completeTurns(in: session.transcript.messages)
        guard !allTurns.isEmpty else { return nil }

        let goal = session.currentGoal
        let currentPlan = session.transcript.currentPlan
        let plan = currentPlan ?? []
        var firstTurn = 0
        while firstTurn < allTurns.count,
              renderedInput(goal: goal, plan: plan, turns: Array(allTurns[firstTurn...])).utf8.count > sourceLimit {
            firstTurn += 1
        }
        guard firstTurn < allTurns.count else { return nil }

        let transcript = session.transcript
        let idleFacts = SessionSummaryIdleFacts(
            agentReady: session.agentState == .ready,
            hydrationReady: session.hydrationState == .ready,
            streamingIsIdle: transcript.streamingState == .idle,
            composerIsEmpty: session.composerDraft.isEmpty,
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
        return .init(
            revision: .init(
                incarnation: session.incarnation,
                transcriptGeneration: transcript.messagesGeneration,
                goal: goal,
                plan: currentPlan,
                idleFacts: idleFacts
            ),
            goal: goal,
            plan: plan,
            turns: Array(allTurns[firstTurn...]),
            omittedOlderTurns: firstTurn > 0
        )
    }

    func messageCandidates() -> [[LocalTextMessage]] {
        turns.indices.map { first in
            [
                .init(role: .system, content: SessionSummaryPolicy.systemPrompt),
                .init(role: .user, content: Self.renderedInput(
                    goal: goal,
                    plan: plan,
                    turns: Array(turns[first...])
                ))
            ]
        }
    }

    @MainActor
    private static func completeTurns(in messages: [ACPMessage]) -> [SessionSummaryTurn] {
        var turns: [SessionSummaryTurn] = []
        var user: String?
        var assistant: [String] = []

        func appendCompleteTurn() {
            guard let user, !assistant.isEmpty else { return }
            turns.append(.init(user: user, assistant: assistant.joined(separator: "\n")))
        }

        for message in messages {
            switch message {
            case .user(_, _, let text, let attachments, let delegatedSource):
                appendCompleteTurn()
                assistant.removeAll(keepingCapacity: true)
                if delegatedSource == nil, attachments.isEmpty,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    user = text
                } else {
                    user = nil
                }
            case .agent(_, _, let text):
                guard user != nil,
                      !text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                assistant.append(text.value)
            default:
                continue
            }
        }
        appendCompleteTurn()
        return turns
    }

    private static func renderedInput(
        goal: ACPGoalState?,
        plan: [ACPMessage.PlanItem],
        turns: [SessionSummaryTurn]
    ) -> String {
        struct Input: Encodable {
            struct Goal: Encodable {
                let objective: String
                let status: String?
                let tokenBudget: Int?
            }
            struct PlanItem: Encodable {
                let content: String
                let status: String
            }
            struct Entry: Encodable {
                let role: String
                let content: String
            }

            let goal: Goal?
            let plan: [PlanItem]
            let conversation: [Entry]
        }

        let input = Input(
            goal: goal.map { .init(objective: $0.objective, status: $0.status, tokenBudget: $0.tokenBudget) },
            plan: plan.map { .init(content: $0.content, status: $0.status) },
            conversation: turns.flatMap {
                [Input.Entry(role: "user", content: $0.user),
                 Input.Entry(role: "assistant", content: $0.assistant)]
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(input), as: UTF8.self)
    }
}
