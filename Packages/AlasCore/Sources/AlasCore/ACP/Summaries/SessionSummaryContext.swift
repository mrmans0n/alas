import CryptoKit
import Foundation

public struct SessionSummaryContext: Equatable, Sendable {
    public static let sourceLimit = 128 * 1024
    public static let tokenLimit = 8_192

    public let revision: SessionSummarySourceRevision?
    public let goal: ACPGoalState?
    public let plan: [ACPMessage.PlanItem]
    public let turns: [SessionSummaryTurn]
    public let omittedOlderTurns: Bool

    /// Cheap gate for showing the summarize control: stops at the first complete turn.
    @MainActor
    public static func hasCompleteTurn(session: ACPSession) -> Bool {
        completeTurnCount(session: session, limit: 1) > 0
    }

    /// Complete turns over the whole transcript, counting no further than `limit`.
    @MainActor
    public static func completeTurnCount(session: ACPSession, limit: Int) -> Int {
        SessionSummarySource.turns(in: session.transcript.messages, limit: limit).count
    }

    @MainActor
    public static func snapshot(session: ACPSession) -> SessionSummaryContext? {
        let revision = SessionSummarySourceRevision.current(session: session, composer: session.composer)
        let allTurns = SessionSummarySource.turns(in: session.transcript.messages)
        return make(
            source: .init(goal: revision.goal, plan: revision.plan ?? [], turns: allTurns),
            revision: revision
        )
    }

    /// Build from a store-loaded source (no live session); `revision` is nil.
    public static func snapshot(source: SessionSummarySource) -> SessionSummaryContext? {
        make(source: source, revision: nil)
    }

    private static func make(
        source: SessionSummarySource,
        revision: SessionSummarySourceRevision?
    ) -> SessionSummaryContext? {
        let allTurns = source.turns
        guard !allTurns.isEmpty else { return nil }
        var lowerBound = 0
        var upperBound = allTurns.count
        while lowerBound < upperBound {
            let candidate = lowerBound + (upperBound - lowerBound) / 2
            let fits = SessionSummarySource.renderedInput(
                goal: source.goal,
                plan: source.plan,
                turns: Array(allTurns[candidate...])
            ).utf8.count <= sourceLimit
            if fits {
                upperBound = candidate
            } else {
                lowerBound = candidate + 1
            }
        }
        let firstTurn = lowerBound
        guard firstTurn < allTurns.count else { return nil }

        return .init(
            revision: revision,
            goal: source.goal,
            plan: source.plan,
            turns: Array(allTurns[firstTurn...]),
            omittedOlderTurns: firstTurn > 0
        )
    }

    public func messageCandidates() -> [[LocalTextMessage]] {
        var retainedTurnCount = turns.count
        var candidates: [[LocalTextMessage]] = []
        while retainedTurnCount > 0 {
            let first = turns.count - retainedTurnCount
            candidates.append([
                .init(role: .system, content: SessionSummaryPolicy.systemPrompt),
                .init(role: .user, content: SessionSummarySource.renderedInput(
                    goal: goal,
                    plan: plan,
                    turns: Array(turns[first...])
                ))
            ])
            if retainedTurnCount == 1 { break }
            retainedTurnCount = (retainedTurnCount + 1) / 2
        }
        return candidates
    }

    /// SHA-256 hex over systemPrompt + NUL + renderedInput(all retained turns) + NUL + modelID.
    public func inputHash(modelID: String) -> String {
        let payload = SessionSummaryPolicy.systemPrompt
            + "\u{0}" + SessionSummarySource.renderedInput(goal: goal, plan: plan, turns: turns)
            + "\u{0}" + modelID
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public init(revision: SessionSummarySourceRevision?, goal: ACPGoalState?, plan: [ACPMessage.PlanItem], turns: [SessionSummaryTurn], omittedOlderTurns: Bool) {
        self.revision = revision
        self.goal = goal
        self.plan = plan
        self.turns = turns
        self.omittedOlderTurns = omittedOlderTurns
    }
}
