import Testing
import AlasACP
@testable import Alas

@MainActor
@Suite("ACP session fork presentation")
struct ACPSessionForkPresentationTests {
    private nonisolated static func forkPoint(
        _ boundary: ACPForkPointBoundary, _ outcome: ACPSessionForkPoint.Outcome?
    ) -> ACPSessionForkPoint {
        ACPSessionForkPoint(
            target: .init(messageId: "m1", messageFingerprint: "sha256:x", messageOccurrence: 1),
            boundary: boundary,
            outcome: outcome
        )
    }

    private nonisolated static func echo(_ boundary: ACPForkPointBoundary) -> ACPSessionForkPoint.Outcome {
        .matched(.init(boundary: boundary, messageId: "m1", matchedBy: .id))
    }

    private nonisolated static let importedNotice =
        "Provider-specific tool state, hidden context, and attachments were not transferred. This chat shares the source chat’s current worktree."

    struct CopyRow: Sendable, CustomTestStringConvertible {
        let name: String
        let mechanism: ACPSessionForkMechanism
        let via: ACPSessionForkVia?
        let forkPoint: ACPSessionForkPoint?
        let boundaryText: String?
        let title: String
        let notice: String?
        var testDescription: String { name }
    }

    @Test("divider copy names the real boundary and the unmatched reason", arguments: [
        CopyRow(name: "plain native", mechanism: .nativeACP, via: nil, forkPoint: nil, boundaryText: nil,
                title: "Forked from Claude", notice: nil),
        CopyRow(name: "imported", mechanism: .transcriptTransfer, via: nil, forkPoint: nil, boundaryText: nil,
                title: "Conversation imported from Claude", notice: importedNotice),
        CopyRow(name: "imported via btw", mechanism: .transcriptTransfer, via: .btw, forkPoint: nil, boundaryText: nil,
                title: "Conversation imported from Claude via /btw", notice: importedNotice),
        CopyRow(name: "matched message", mechanism: .nativeACP, via: nil,
                forkPoint: forkPoint(.message, echo(.message)),
                boundaryText: "  \n\nFirst   line of a very long answer that keeps going past the limit\nsecond",
                title: "Forked from Claude after “First line of a very long answer that keeps goin…”",
                notice: nil),
        CopyRow(name: "matched message, blank preview", mechanism: .nativeACP, via: nil,
                forkPoint: forkPoint(.message, echo(.message)), boundaryText: "  \n ",
                title: "Forked from Claude after this message", notice: nil),
        CopyRow(name: "matched turn", mechanism: .nativeACP, via: nil,
                forkPoint: forkPoint(.turn, echo(.turn)), boundaryText: "ignored",
                title: "Forked from Claude after this turn", notice: nil),
        CopyRow(name: "unmatched notFound", mechanism: .transcriptTransfer, via: nil,
                forkPoint: forkPoint(.message, .unmatched(.notFound)), boundaryText: "hi",
                title: "Conversation imported from Claude",
                notice: "Claude couldn't find this message in its history, so the conversation was imported instead of forked natively. " + importedNotice),
        CopyRow(name: "unmatched mismatchedEcho", mechanism: .transcriptTransfer, via: nil,
                forkPoint: forkPoint(.message, .unmatched(.mismatchedEcho)), boundaryText: nil,
                title: "Conversation imported from Claude",
                notice: "Claude forked at a different point, so that fork was discarded and the conversation was imported instead. " + importedNotice),
        CopyRow(name: "unmatched unavailable", mechanism: .transcriptTransfer, via: nil,
                forkPoint: forkPoint(.message, .unmatched(.unavailable)), boundaryText: nil,
                title: "Conversation imported from Claude",
                notice: "Claude couldn't fork at this message right now, so the conversation was imported instead. " + importedNotice),
    ])
    func dividerCopy(row: CopyRow) {
        let presentation = ACPSessionForkPresentation(
            sourceAgentName: "Claude", mechanism: row.mechanism, via: row.via,
            forkPoint: row.forkPoint, boundaryText: row.boundaryText
        )
        #expect(presentation.title == row.title)
        #expect(presentation.notice == row.notice)
    }

    @Test("current target is first and remaining targets preserve ACP catalog order")
    func targetOrdering() {
        let targets = ACPForkTargetPolicy.targets(
            sourceAgentID: "codex",
            enabledAgents: [
                .init(id: "claude", displayName: "Claude", logoAssetName: "agent-claude"),
                .init(id: "gemini", displayName: "Gemini", logoAssetName: "agent-gemini"),
                .init(id: "codex", displayName: "Codex", logoAssetName: "agent-codex")
            ],
            catalogAgentIDs: ["claude", "gemini", "codex"]
        )
        #expect(targets.map(\.id) == ["codex", "claude", "gemini"])
        #expect(targets.first?.isSameAgent == true)
        #expect(targets.first?.logoAssetName == "agent-codex")
    }

    @Test("message menu only offers fork for eligible rows")
    func menuEligibility() {
        #expect(ACPMessageForkMenuPolicy.showsForkAction(
            messageKind: "user", isEligible: true, targetCount: 2
        ))
        #expect(!ACPMessageForkMenuPolicy.showsForkAction(
            messageKind: "agent", isEligible: false, targetCount: 2
        ))
        #expect(!ACPMessageForkMenuPolicy.showsForkAction(
            messageKind: "tool_call", isEligible: true, targetCount: 2
        ))
    }
}
