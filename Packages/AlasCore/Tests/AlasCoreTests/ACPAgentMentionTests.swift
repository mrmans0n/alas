import Foundation
import Testing
import AlasCore
import AlasRemoteKit
@testable import AlasSessions
@testable import AlasAgentKit

struct ACPAgentMentionTests {
    @Test(arguments: [
        ACPAgentReference.Target(agentId: "codex", model: nil),
        ACPAgentReference.Target(agentId: "codex", model: "gpt-6.2-sol"),
        ACPAgentReference.Target(agentId: "omp", model: "ollama-cloud/kimi-k2.6:cloud"),
    ])
    func agentLinkRoundTrips(_ target: ACPAgentReference.Target) {
        #expect(ACPAgentReference.target(fromURI: ACPAgentReference.uri(for: target)) == target)
    }

    @Test func linksReplaceOnlyAgentReferencesWithTheirDelegationArguments() {
        let agentLink = ACPAgentReference.uri(for: .init(agentId: "codex", model: "gpt-6.2-sol"))
        let others: [ACPContentBlock] = [
            .text("ask "),
            .resourceLink(uri: "file:///repo/a.swift", name: "a.swift"),
            .resourceLink(uri: "alas-session://s1", name: "Other"),
        ]
        let replaced = ACPAgentReference.replacingReferences(
            in: [others[0], .resourceLink(uri: agentLink, name: "Codex · 6.2 Sol"), others[1], others[2]])

        #expect(replaced.count == 4)
        #expect(Array(replaced[2...]) == Array(others[1...]))
        guard case .text(let note) = replaced[1] else {
            Issue.record("agent link was not replaced with text")
            return
        }
        #expect(note.hasPrefix("@Codex · 6.2 Sol "))
        #expect(note.contains(#"session_new tool (agent "codex", model "gpt-6.2-sol")"#))
    }

    private static let catalog: [ACPAgentMentionCandidate] = [
        .init(agentId: "claude", agentName: "Claude Code"),
        .init(agentId: "claude", agentName: "Claude Code", modelId: "opus", modelName: "Opus 5.5"),
        .init(agentId: "codex", agentName: "Codex"),
        .init(agentId: "codex", agentName: "Codex", modelId: "gpt-6.2-sol", modelName: "6.2 Sol"),
        .init(agentId: "codex", agentName: "Codex", modelId: "gpt-6.1-terra", modelName: "6.1 Terra"),
        .init(agentId: "omp", agentName: "OMP"),
        .init(agentId: "omp", agentName: "OMP", modelId: "openai-codex/gpt-6-sol", modelName: "GPT-6-Sol"),
    ]

    @Test(arguments: [
        ("", []),
        ("c", []),
        ("laude", []),
        ("codex", ["codex/", "codex/gpt-6.2-sol", "codex/gpt-6.1-terra", "omp/openai-codex/gpt-6-sol"]),
        ("codex:sol", ["codex/gpt-6.2-sol", "omp/openai-codex/gpt-6-sol"]),
        ("6.2", ["codex/gpt-6.2-sol"]),
        ("opus", ["claude/opus"]),
    ] as [(String, [String])])
    func rankingMatchesWordPrefixesAgentsFirst(query: String, expected: [String]) {
        let ranked = MentionAgentRanking.rank(Self.catalog, query: query)
        #expect(ranked.map { "\($0.agentId)/\($0.modelId ?? "")" } == expected)
    }
}
