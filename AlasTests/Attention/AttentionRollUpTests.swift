import Foundation
import Testing
@testable import Alas

struct AttentionRollUpTests {
    private let references = (0..<3).map { _ in UUID() }

    @Test func parseMapsGroupsToSourceItemsInInboxOrder() throws {
        let output = """
        {"groups": [
          {"summary": "A run script failed on the inbox branch.", "items": [3]},
          {"summary": "Two agents are waiting on you in the same worktree.", "items": [2, 1]}
        ]}
        """

        let groups = try #require(AttentionRollUpPolicy.parse(output, references: references))

        #expect(groups.map(\.eventIDs) == [[references[0], references[1]], [references[2]]])
        #expect(groups.map(\.summary) == [
            "Two agents are waiting on you in the same worktree.",
            "A run script failed on the inbox branch.",
        ])
    }

    @Test(arguments: [
        #"{"groups": [{"summary": "Agents are waiting.", "items": [1, 2]}]}"#,
        #"{"groups": [{"summary": "Agents are waiting.", "items": [1, 2]}, {"summary": "A run failed.", "items": [2, 3]}]}"#,
        #"{"groups": [{"summary": "Agents are waiting.", "items": [1, 1, 2, 3]}]}"#,
        #"{"groups": [{"summary": "Agents are waiting.", "items": [0, 1, 2, 3]}]}"#,
        #"{"groups": [{"summary": "Agents are waiting.", "items": [1, 2, 3, 4]}]}"#,
        #"{"groups": [{"summary": "Agents are waiting.", "items": [1, 2, 3]}, {"summary": "Nothing.", "items": []}]}"#,
        #"{"groups": [{"summary": "Agents are waiting.", "items": [1, 2.5, 3]}]}"#,
        #"{"groups": [{"summary": "Agents are waiting.", "items": [1, 2, 3], "severity": "low"}]}"#,
        #"{"groups": [{"summary": "Agents are waiting.", "items": [1, 2, 3]}], "order": [3, 1, 2]}"#,
        #"Agents are waiting."#,
    ])
    func parseRejectsOutputThatDoesNotCiteEveryShownItemOnce(_ output: String) {
        #expect(AttentionRollUpPolicy.parse(output, references: references) == nil)
    }

    @Test(arguments: [
        "Urgent: two agents need permission.",
        "Handle the merge conflicts first.",
        "These checks are low priority.",
        "The failing run was already resolved.",
        "Both requests have been acknowledged.",
        "Agents are waiting. A run failed too.",
        "Agents are waiting, see https://example.com.",
        "Codex mentioned @someone in a reply.",
    ])
    func parseRejectsSummariesThatRankItemsOrClaimTheirState(_ summary: String) {
        let output = #"{"groups": [{"summary": "\#(summary)", "items": [1, 2, 3]}]}"#
        #expect(AttentionRollUpPolicy.parse(output, references: references) == nil)
    }

    @Test func requestShowsOnlyBoundedReferencesAndDisclosesTheRest() {
        let items = (0..<15).map { makeItem(title: "Agent \($0) " + String(repeating: "x", count: 400)) }

        let request = AttentionRollUpPolicy.request(for: items)
        let payload = request.messages.last?.content ?? ""

        #expect(!request.references.isEmpty)
        #expect(request.references.count < items.count)
        #expect(request.references == items.prefix(request.references.count).map(\.eventID))
        #expect(payload.utf8.count <= AttentionRollUpPolicy.payloadByteBudget)
        #expect(!items.contains { payload.contains($0.eventID.uuidString) })
        #expect(request.coverage.itemsShown == request.references.count)
        #expect(request.coverage.shortenedItems == request.references.count)
        #expect(request.coverage.disclosure?.contains("of 15 items") == true)
    }

    @Test @MainActor func summarizerKeepsTheSourceItemsTheModelCited() async throws {
        let items = [makeItem(title: "Codex is waiting for input"), makeItem(title: "Claude needs permission")]
        let summarizer = AttentionRollUpSummarizer(
            engine: UnavailableEngine(),
            isAppleIntelligenceAvailable: { true },
            generateWithAppleIntelligence: { _ in
                #"{"groups": [{"summary": "Two agents are waiting on you.", "items": [1, 2]}]}"#
            },
            isMLXAvailable: { false }
        )

        let rollUp = try #require(await summarizer.rollUp(items))

        #expect(rollUp.sourceItems == items)
        #expect(rollUp.groups.map { rollUp.items(in: $0).map(\.title) } == [[
            "Codex is waiting for input", "Claude needs permission",
        ]])
    }

    enum InboxChange: CaseIterable {
        case none, added, acknowledged, retitled, unverified
    }

    @Test(arguments: InboxChange.allCases)
    func rollUpIsOnlyCurrentForTheItemsItWasDraftedFrom(_ change: InboxChange) {
        let items = [makeItem(title: "Codex is waiting for input"), makeItem(title: "Run failed")]
        let rollUp = AttentionRollUp(
            groups: [.init(summary: "Work is waiting.", eventIDs: items.map(\.eventID))],
            sourceItems: items,
            coverage: .init(itemsShown: 2, itemCount: 2)
        )
        let current: [AttentionItem] = switch change {
        case .none: items
        case .added: items + [makeItem(title: "Claude needs permission")]
        case .acknowledged: [items[1]]
        case .retitled: [makeItem(from: items[0], title: "Codex is waiting for input again"), items[1]]
        case .unverified: [makeItem(from: items[0], presentation: .unverified), items[1]]
        }

        let phase = AttentionRollUpPhase.resolve(isSummarizing: false, rollUp: rollUp, currentItems: current)

        #expect(phase == (change == .none ? .current(rollUp) : .stale))
    }

    private func makeItem(title: String) -> AttentionItem {
        let display = AttentionWorktreeDisplaySnapshot(projectName: "Alas", branch: "feature/inbox", path: "/repo", host: nil)
        return AttentionItem(
            eventID: UUID(), sourceKey: .init(rawValue: title),
            owner: .init(projectID: "p1", location: .local, lineageID: "lineage", legacyPath: nil),
            kind: .agentAwaiting, title: title, body: nil, occurredAt: Date(timeIntervalSince1970: 100),
            presentation: .live, jumpTarget: .session(sessionID: "s1"), display: display,
            worktree: nil, acknowledgedAt: nil
        )
    }

    private func makeItem(from item: AttentionItem, title: String? = nil,
                          presentation: AttentionItemPresentation? = nil) -> AttentionItem {
        AttentionItem(
            eventID: item.eventID, sourceKey: item.sourceKey, owner: item.owner, kind: item.kind,
            title: title ?? item.title, body: item.body, occurredAt: item.occurredAt,
            presentation: presentation ?? item.presentation, jumpTarget: item.jumpTarget,
            display: item.display, worktree: item.worktree, acknowledgedAt: item.acknowledgedAt
        )
    }
}

private struct UnavailableEngine: LocalTextGenerating {
    func generate(_ request: LocalTextGenerationRequest, caller: LocalTextCaller,
                  priority: LocalTextJobPriority) async throws -> LocalTextGenerationResult {
        throw LocalTextInferenceFailure.unavailable
    }

    func cancel(caller: LocalTextCaller) async {}
    func cancelAndUnload() async {}
}
