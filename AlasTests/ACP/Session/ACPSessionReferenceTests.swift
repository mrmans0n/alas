import Foundation
import Testing
@testable import Alas

@Suite("ACP session reference")
struct ACPSessionReferenceTests {
    private let target = ACPSessionReference.Target(
        sessionId: "s-1", title: "Fix parser", agentName: "Codex", worktreeName: "feature-x"
    )

    @Test("a session id survives the URI round trip; other URIs are not sessions",
          arguments: ["7A1C-UUID", "id with/odd:chars"])
    func uriRoundTrip(sessionId: String) {
        #expect(ACPSessionReference.sessionId(fromURI: ACPSessionReference.uri(sessionId: sessionId)) == sessionId)
        #expect(ACPSessionReference.sessionId(fromURI: "file:///tmp/\(sessionId)") == nil)
        #expect(ACPSessionReference.sessionId(fromURI: "alas-session://") == nil)
    }

    @Test("session links become their context on the wire; files and unresolved sessions are handled apart")
    func replacesSessionLinks() {
        let blocks: [ACPContentBlock] = [
            .text("Compare with @Fix parser "),
            .resourceLink(uri: ACPSessionReference.uri(sessionId: "s-1"), name: "Fix parser"),
            .resourceLink(uri: "file:///tmp/a.swift", name: "a.swift"),
            .resourceLink(uri: ACPSessionReference.uri(sessionId: "gone"), name: "Old chat"),
            .resourceLink(uri: ACPSessionReference.uri(sessionId: "s-1"), name: "Fix parser"),
        ]

        #expect(ACPSessionReference.sessionIds(in: blocks) == ["s-1", "gone"])
        let wire = ACPSessionReference.replacingReferences(in: blocks, contexts: ["s-1": "CONTEXT"])

        #expect(wire[0] == blocks[0])
        #expect(wire[1] == .text("CONTEXT"))
        #expect(wire[2] == blocks[2])
        guard case .text(let missing) = wire[3] else {
            Issue.record("Expected a text block, got \(wire[3])")
            return
        }
        #expect(missing.contains("session_id=\"gone\""))
        #expect(missing.contains("\"Old chat\""))
        #expect(missing.contains("not available"))
        #expect(wire[4] == .text("CONTEXT"))
    }

    @Test("context names the session and how to read it, and keeps the latest entries within budget")
    func contextKeepsLatestEntriesWithinBudget() {
        // Paging back from the latest entry stops at the one too large to fit.
        let entries: [ACPSessionTranscriptReader.Entry] = [
            .init(index: 0, role: "user", text: "First question"),
            .init(index: 1, role: "agent", text: String(repeating: "x", count: ACPSessionReference.contextMaxChars)),
            .init(index: 2, role: "agent", text: "Latest answer"),
            .init(index: 3, role: "user", text: "Latest question"),
        ]

        let context = ACPSessionReference.context(for: target, entries: entries)

        #expect(context.hasPrefix("<alas-session-reference session_id=\"s-1\">"))
        #expect(context.hasSuffix("</alas-session-reference>"))
        #expect(context.contains("\"Fix parser\" (agent: Codex, worktree: feature-x)"))
        #expect(context.contains("session_read"))
        #expect(context.contains("latest 2 entries"))
        #expect(context.contains("[user] Latest question"))
        #expect(!context.contains("First question"))
        #expect(context.count <= ACPSessionReference.contextMaxChars)
    }

    @Test("the whole block, wrapper and labels included, stays within the budget")
    func contextBlockNeverExceedsBudget() {
        let longTarget = ACPSessionReference.Target(
            sessionId: "s-1", title: String(repeating: "t", count: 5_000),
            agentName: String(repeating: "a", count: 5_000), worktreeName: String(repeating: "w", count: 5_000)
        )
        let entries = (0..<200).map {
            ACPSessionTranscriptReader.Entry(index: $0, role: $0.isMultiple(of: 2) ? "user" : "agent", text: String(repeating: "y", count: 150))
        }

        let context = ACPSessionReference.context(for: longTarget, entries: entries)

        #expect(context.count <= ACPSessionReference.contextMaxChars)
        #expect(context.contains(String(repeating: "t", count: ACPSessionReference.contextTitleLimit) + "…\""))
        #expect(context.hasSuffix("</alas-session-reference>"))
    }

    @Test("context of a session with no messages says so")
    func contextOfEmptySession() {
        #expect(ACPSessionReference.context(for: target, entries: []).contains("no messages yet"))
    }

    @Test("only the user's own prompts attach sessions")
    @MainActor
    func attachedSessionIdsSkipDelegatedPrompts() {
        let link = { (id: String) in ACPMessage.Attachment(uri: ACPSessionReference.uri(sessionId: id), name: id) }
        let delegated = ACPDelegatedPromptSource(sessionId: "child", messageId: "m-1")
        let messages: [ACPMessage] = [
            .user(id: UUID(), text: "see", attachments: [link("by-user"), .init(uri: "file:///a", name: "a")]),
            .user(id: UUID(), messageId: nil, text: "see", attachments: [link("by-agent")], delegatedSource: delegated),
        ]

        #expect(ACPSessionReference.attachedSessionIds(in: messages) == ["by-user"])
    }
}
