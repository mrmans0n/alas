import Foundation
import Testing
@testable import Alas

@Suite("ACP delegated outcome text")
struct ACPDelegatedOutcomeTextTests {
    private let context = ACPDelegatedOutcomeText.Context(
        childSessionId: "child-1", agentId: "codex", worktreeName: "feature-x"
    )

    @Test("unreported completion names the child and quotes its last message")
    func unreportedWithText() {
        let text = ACPDelegatedOutcomeText.unreported(context, lastAgentText: "Parser fixed.")
        #expect(text.hasPrefix("[alas system] Delegated session child-1 (codex, worktree feature-x) finished its turn without sending a result."))
        #expect(text.contains("Last message from the child:\nParser fixed."))
        #expect(text.hasSuffix("Use session_send to follow up with it, or session_list to inspect its state."))
        #expect(!text.lowercased().contains("acknowledge"))
    }

    @Test("unreported completion without agent text omits the quote block")
    func unreportedWithoutText() {
        let text = ACPDelegatedOutcomeText.unreported(context, lastAgentText: nil)
        #expect(!text.contains("Last message from the child"))
        #expect(text.contains("finished its turn without sending a result."))
    }

    @Test("omits the worktree clause when the name is unknown")
    func noWorktreeName() {
        let bare = ACPDelegatedOutcomeText.Context(childSessionId: "c", agentId: "claude", worktreeName: nil)
        #expect(ACPDelegatedOutcomeText.notice(bare) == "Delegated session c (claude) finished its turn.")
    }

    @Test("failure text carries the failure message")
    func failure() {
        #expect(ACPDelegatedOutcomeText.failure(context, message: "Agent is not enabled")
            == "[alas system] Delegated session child-1 (codex, worktree feature-x) failed: Agent is not enabled.")
    }

    @Test("tail keeps the last characters and marks truncation")
    func tailTruncates() {
        let long = String(repeating: "a", count: 10) + "END"
        #expect(ACPDelegatedOutcomeText.tail(long, limit: 5) == "…" + "aaEND")
        #expect(ACPDelegatedOutcomeText.tail("short", limit: 5) == "short")
        #expect(ACPDelegatedOutcomeText.tail("  padded \n", limit: 50) == "padded")
    }

    @Test("escalated blocker copy states the parent cannot approve")
    func escalatedBlockerCopy() {
        let text = ACPDelegatedOutcomeText.blocker(
            context, kindLabel: "permission", waitedSeconds: 30, escalated: true
        )
        #expect(text.hasPrefix("[alas system] Delegated session child-1 (codex, worktree feature-x)"))
        #expect(text.contains("30s"))
        #expect(text.contains("cannot approve"))
        #expect(text.contains("notify"))
        #expect(text.contains("session_send"))
    }

    @Test("non-escalated blocker copy is a plain notice")
    func nonEscalatedBlockerCopy() {
        let text = ACPDelegatedOutcomeText.blocker(
            context, kindLabel: "question", waitedSeconds: 0, escalated: false
        )
        #expect(!text.hasPrefix("[alas system]"))
        #expect(text.contains("waiting for a human decision"))
        #expect(!text.lowercased().contains("acknowledge"))
    }

    @Test("blocker copy caps an oversized summary and strips embedded newlines")
    func blockerCopySanitizesSummary() {
        var longContext = context
        longContext.blockerSummary = String(repeating: "x", count: 500) + "\nsecond line"
        let text = ACPDelegatedOutcomeText.blocker(
            longContext, kindLabel: "question", waitedSeconds: 0, escalated: false
        )
        #expect(!text.contains("\n"))
        #expect(text.count < 500)
    }

    // MARK: - Delivered prompt source and transcript label

    private static func delegation(child: String, parent: String) -> ACPDelegationRecord {
        .init(
            childSessionId: child, parentSessionId: parent, projectId: "p",
            parentWorktreeId: "w", childWorktreeId: "w", agentId: "codex",
            worktreeRequest: .current(worktreeId: "w"), pendingInitialPrompt: nil,
            phase: .ready, failureMessage: nil, createdAt: 1, updatedAt: 1
        )
    }

    struct Delivery: Sendable, CustomTestStringConvertible {
        let source: String
        let target: String
        /// The delegation record whose child is `source`, if any.
        let senderDelegation: ACPDelegationRecord?
        let label: String
        var testDescription: String { "\(source) → \(target)" }
    }

    static let deliveries: [Delivery] = [
        .init(source: "c4f1a2b3-9d", target: "parent",
              senderDelegation: delegation(child: "c4f1a2b3-9d", parent: "parent"),
              label: "Report from Codex child · c4f1a2b3"),
        // Parent→child: the sender is a root, or itself the child of a third session.
        .init(source: "parent", target: "c4f1a2b3-9d", senderDelegation: nil, label: "Delegated prompt"),
        .init(source: "parent", target: "c4f1a2b3-9d",
              senderDelegation: delegation(child: "parent", parent: "root"), label: "Delegated prompt"),
        .init(source: "mission:s1", target: "s1", senderDelegation: nil, label: "Delegated prompt"),
    ]

    @Test("a delivered prompt is labelled as a child report only when its sender is the target's child", arguments: deliveries)
    func deliveredLabel(_ delivery: Delivery) {
        let message = ACPDelegatedMessage(
            id: "m1", sourceSessionId: delivery.source, targetSessionId: delivery.target, prompt: "x", createdAt: 1
        )
        let source = ACPDelegatedPromptSource(message: message, senderDelegation: delivery.senderDelegation)
        #expect(source.isSameDelivery(as: .init(sessionId: delivery.source, messageId: "m1")))
        let label = ACPDelegatedPromptSource.transcriptLabel(for: source) { $0 == "codex" ? "Codex" : $0 }
        #expect(label == delivery.label)
    }

    @Test("a persisted source from before sender fields, or with an unknown relationship, decodes to the generic label", arguments: [
        #"{"sessionId":"parent","messageId":"m1"}"#,
        #"{"sessionId":"parent","messageId":"m1","senderRelationship":"sibling","senderAgentId":"codex"}"#,
    ])
    func legacySourceDecodes(json: String) throws {
        let source = try JSONDecoder().decode(ACPDelegatedPromptSource.self, from: Data(json.utf8))
        #expect(source.isSameDelivery(as: .init(sessionId: "parent", messageId: "m1")))
        #expect(ACPDelegatedPromptSource.transcriptLabel(for: source) { $0 } == "Delegated prompt")
    }
}
