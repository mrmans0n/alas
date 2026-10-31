import Foundation
import Testing
import AlasCore

struct ACPSubagentObservationTests {
    @Test("a child's config snapshot projects to model and effort labels", arguments: [true, false])
    func configSummary(confirmed: Bool) throws {
        let options = [
            ACPConfigOption(id: "model", name: "Model", category: "model", currentValue: .string("gpt-5"),
                            options: [.init(id: "gpt-5", name: "GPT-5")]),
            ACPConfigOption(id: "reasoning_effort", name: "Effort", category: "thought_level",
                            currentValue: .string("high"),
                            options: [.init(id: "high", name: "High")])]
        let summary = try #require(ACPSubagentConfigSummary.make(
            agentId: "codex", configOptions: options, isConfirmed: confirmed))
        #expect(summary.model == "GPT-5")
        #expect(summary.effort == "High")
        #expect(summary.isConfirmed == confirmed)
        #expect(ACPSubagentConfigSummary.make(agentId: "codex", configOptions: [], isConfirmed: true) == nil)
    }

    @Test("a delegation's counterpart prefers a visible tool call, else the child's own row", arguments: [
        (Set(["toolu_1"]), ACPDelegationNavigationTarget.parentToolCall(toolCallId: "toolu_1")),
        (Set<String>(), .subagentRow(subagentSessionId: "c1")),
    ])
    func navigationTargets(toolCalls: Set<String>, expected: ACPDelegationNavigationTarget) {
        let link = ACPDelegationLink(messageId: "toolu_1", senderSessionId: "root", recipientSessionId: "c1", senderMessageId: "toolu_1")
        #expect(ACPDelegationNavigation.counterpart(of: link, viewingSessionId: "c1", rootSessionId: "root",
                parentToolCallIds: toolCalls, knownChildIds: ["c1"]) == expected)
        #expect(ACPDelegationNavigation.counterpart(of: link, viewingSessionId: "root", rootSessionId: "root",
                parentToolCallIds: toolCalls, knownChildIds: ["c1"]) == .childMessage(subagentSessionId: "c1", messageId: "toolu_1"))
    }

    @Test("a child's handback, seen from the root, leads to the child's own row for it")
    func handbackNavigatesToChildMessage() {
        let link = ACPDelegationLink(messageId: "toolu_h", senderSessionId: "c1", recipientSessionId: "root",
                                     senderMessageId: "toolu_h")
        #expect(ACPDelegationNavigation.counterpart(of: link, viewingSessionId: "root", rootSessionId: "root",
                parentToolCallIds: [], knownChildIds: ["c1"]) == .childMessage(subagentSessionId: "c1", messageId: "toolu_h"))
        #expect(ACPDelegationNavigation.counterpart(of: link, viewingSessionId: "root", rootSessionId: "root",
                parentToolCallIds: [], knownChildIds: []) == nil)
    }

    @Test("two partial views of a delegation merge without overwriting a known member")
    func linkMerge() {
        var link = ACPDelegationLink(messageId: "toolu_1", senderSessionId: "root", recipientSessionId: nil,
                                     recipientMessageId: "toolu_1")
        link.merge(ACPDelegationLink(messageId: "toolu_1", senderSessionId: "other", recipientSessionId: "c1",
                                     senderMessageId: "toolu_s", recipientMessageId: "other"))
        #expect(link == ACPDelegationLink(messageId: "toolu_1", senderSessionId: "root", recipientSessionId: "c1",
                                          senderMessageId: "toolu_s", recipientMessageId: "toolu_1"))
    }
}
