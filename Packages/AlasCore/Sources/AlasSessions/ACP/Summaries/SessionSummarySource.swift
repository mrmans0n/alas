import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

/// Everything the session summary is derived from, independent of whether it
/// came from a live `ACPSession` or from persisted rows.
public struct SessionSummarySource: Equatable, Sendable {
    public let goal: ACPGoalState?
    public let plan: [ACPMessage.PlanItem]
    /// All complete turns, oldest first.
    public let turns: [SessionSummaryTurn]

    public init(goal: ACPGoalState?, plan: [ACPMessage.PlanItem], turns: [SessionSummaryTurn]) {
        self.goal = goal
        self.plan = plan
        self.turns = turns
    }

    /// Reduced view of a message shared by the live and persisted representations.
    enum Event {
        case user(text: String, hasAttachments: Bool, isDelegated: Bool)
        case agent(text: String)
        case other
    }

    /// Turns from wire messages; same rules as the live transcript path.
    public static func turns(in messages: [ACPMessageWire], limit: Int = .max) -> [SessionSummaryTurn] {
        turns(events: messages.lazy.map(Event.init(wire:)), limit: limit)
    }

    /// Latest `.plan` message after the last `.user` message, else `[]`
    /// (mirrors `ACPTranscript.currentPlan`).
    public static func currentPlan(in messages: [ACPMessageWire]) -> [ACPMessage.PlanItem] {
        for message in messages.reversed() {
            switch message {
            case .plan(let items): return items
            case .user: return []
            default: continue
            }
        }
        return []
    }

    @MainActor
    static func turns(in messages: [ACPMessage], limit: Int = .max) -> [SessionSummaryTurn] {
        turns(events: messages.lazy.map(Event.init(message:)), limit: limit)
    }

    static func turns<S: Sequence>(events: S, limit: Int) -> [SessionSummaryTurn] where S.Element == Event {
        var turns: [SessionSummaryTurn] = []
        var user: String?
        var assistant: [String] = []

        func appendCompleteTurn() {
            guard let user, !assistant.isEmpty else { return }
            turns.append(.init(user: user, assistant: assistant.joined(separator: "\n")))
        }

        for event in events {
            switch event {
            case .user(let text, let hasAttachments, let isDelegated):
                appendCompleteTurn()
                if turns.count >= limit { return turns }
                assistant.removeAll(keepingCapacity: true)
                if !isDelegated, !hasAttachments,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    user = text
                } else {
                    user = nil
                }
            case .agent(let text):
                guard user != nil,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                assistant.append(text)
            case .other:
                continue
            }
        }
        appendCompleteTurn()
        return turns
    }

    public static func renderedInput(
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

extension SessionSummarySource.Event {
    package init(wire: ACPMessageWire) {
        switch wire {
        case .user(_, let text, let attachments, let delegatedSource, _):
            self = .user(text: text, hasAttachments: !attachments.isEmpty, isDelegated: delegatedSource != nil)
        case .agent(_, let text, _, _):
            self = .agent(text: text)
        default:
            self = .other
        }
    }

    @MainActor
    package init(message: ACPMessage) {
        switch message {
        case .user(_, _, let text, let attachments, let delegatedSource, _):
            self = .user(text: text, hasAttachments: !attachments.isEmpty, isDelegated: delegatedSource != nil)
        case .agent(_, _, let text):
            self = .agent(text: text.value)
        default:
            self = .other
        }
    }
}
