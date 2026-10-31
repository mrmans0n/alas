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

    struct NavigationCase: Sendable, CustomTestStringConvertible {
        let label: String
        let link: ACPDelegationLink
        let viewing: String
        var toolCalls: Set<String> = []
        var knownChildren: Set<String> = ["c1", "c2"]
        let expected: ACPDelegationNavigationTarget?
        var testDescription: String { label }
    }

    static let navigationCases: [NavigationCase] = {
        let launch = ACPDelegationLink(messageId: "toolu_1", senderSessionId: "root", recipientSessionId: "c1",
                                       senderMessageId: "toolu_1")
        // Context recovery gave the root a new id; the link still names the old one.
        let recoveredLaunch = ACPDelegationLink(messageId: "toolu_1", senderSessionId: "root-old",
                                                recipientSessionId: "c1", senderMessageId: "toolu_1")
        let handback = ACPDelegationLink(messageId: "toolu_h", senderSessionId: "c1", recipientSessionId: "root",
                                         senderMessageId: "toolu_h")
        let sibling = ACPDelegationLink(messageId: "toolu_s", senderSessionId: "c2", recipientSessionId: "c1",
                                        senderMessageId: "toolu_s2", recipientMessageId: "toolu_s1")
        return [
            .init(label: "launch, from the child, tool call rendered", link: launch, viewing: "c1",
                  toolCalls: ["toolu_1"], expected: .parentToolCall(toolCallId: "toolu_1")),
            .init(label: "launch, from the child, tool call hidden", link: launch, viewing: "c1",
                  expected: .subagentRow(subagentSessionId: "c1")),
            .init(label: "launch, from the root", link: launch, viewing: "root",
                  expected: .childMessage(subagentSessionId: "c1", messageId: "toolu_1")),
            .init(label: "launch naming a recovered root, from the child", link: recoveredLaunch, viewing: "c1",
                  toolCalls: ["toolu_1"], expected: .parentToolCall(toolCallId: "toolu_1")),
            .init(label: "launch naming a recovered root, from the root", link: recoveredLaunch, viewing: "root-new",
                  expected: .childMessage(subagentSessionId: "c1", messageId: "toolu_1")),
            .init(label: "handback, from the root", link: handback, viewing: "root",
                  expected: .childMessage(subagentSessionId: "c1", messageId: "toolu_h")),
            .init(label: "handback from an unknown child, from the root", link: handback, viewing: "root",
                  knownChildren: [], expected: nil),
            .init(label: "handback, from the child", link: handback, viewing: "c1", expected: nil),
            .init(label: "sibling message, from the recipient", link: sibling, viewing: "c1",
                  expected: .childMessage(subagentSessionId: "c2", messageId: "toolu_s2")),
            .init(label: "sibling message, from the sender", link: sibling, viewing: "c2",
                  expected: .childMessage(subagentSessionId: "c1", messageId: "toolu_s1")),
        ]
    }()

    @Test("a delegation's counterpart is the other side's copy of it", arguments: navigationCases)
    func navigationTargets(_ c: NavigationCase) {
        #expect(ACPDelegationNavigation.counterpart(
            of: c.link, viewingSessionId: c.viewing,
            parentToolCallIds: c.toolCalls, knownChildIds: c.knownChildren) == c.expected)
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
