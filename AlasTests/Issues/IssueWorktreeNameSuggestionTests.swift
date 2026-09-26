import Foundation
import Testing
@testable import Alas

struct IssueWorktreeNameSuggestionTests {
    @Test(arguments: [
        (#"{"name": "offline-sync-conflicts"}"#, "offline-sync-conflicts"),
        (#" {"name":"fix-oauth2"} "#, "fix-oauth2"),
        // A leading echo of the ticket reference is dropped; Alas owns it.
        (#"{"name": "42-offline-sync"}"#, "offline-sync"),
    ])
    func acceptsOnlyABareKebabName(output: String, expected: String) {
        #expect(IssueWorktreeNamePolicy.parse(output, displayReference: "#42") == expected)
    }

    @Test(arguments: [
        "offline-sync",
        #"{"name": "Offline-Sync"}"#,
        #"{"name": "feature/offline-sync"}"#,
        #"{"name": "offline--sync"}"#,
        #"{"name": "offline sync"}"#,
        #"{"name": "123-456"}"#,
        #"{"name": ""}"#,
        #"{"name": "one-two-three-four-five-six"}"#,
        #"{"name": "internationalization-localization-refactor"}"#,
        #"{"name": "offline-sync", "why": "because"}"#,
        #"{"name": null}"#,
        #"```json {"name": "offline-sync"} ```"#,
    ])
    func rejectsAnythingElse(output: String) {
        #expect(IssueWorktreeNamePolicy.parse(output, displayReference: "#42") == nil)
    }

    @Test func inputIsBoundedAndDegradesToTitleOnly() throws {
        let candidates = IssueWorktreeNamePolicy.messageCandidates(
            title: "Fix sync",
            body: String(repeating: "x", count: 50_000)
        )

        let payloads = candidates.map { $0.last?.content ?? "" }
        #expect(payloads.allSatisfy { $0.count < 4_200 })
        #expect(payloads.last == #"{"title":"Fix sync"}"#)
    }

    @Test(arguments: [
        (true, Result<String, LocalTextInferenceFailure>.success(#"{"name": "offline-sync"}"#), "offline-sync", 1),
        (true, .success("offline-sync"), nil, 1),
        (true, .failure(.timedOut), nil, 1),
        (true, .failure(.cancelled), nil, 1),
        (true, .failure(.unsupported), nil, 1),
        (true, .failure(.unavailable), nil, 1),
        (false, .success(#"{"name": "offline-sync"}"#), nil, 0),
    ] as [(Bool, Result<String, LocalTextInferenceFailure>, String?, Int)])
    @MainActor
    func suggesterFallsBackToNilAndSkipsTheEngineWhenUnavailable(
        available: Bool,
        outcome: Result<String, LocalTextInferenceFailure>,
        expected: String?,
        expectedCalls: Int
    ) async {
        let engine = CannedEngine(outcome: outcome)
        let suggester = IssueWorktreeNameSuggester(engine: engine) { available }

        let name = await suggester.suggestName(for: Self.source)

        #expect(name == expected)
        #expect(await engine.calls == expectedCalls)
    }

    @Test @MainActor
    func availabilityRevokedDuringGenerationDiscardsAValidName() async {
        let availability = Availability()
        let engine = CannedEngine(outcome: .success(#"{"name": "offline-sync"}"#)) {
            // The last enabling capability turns off while inference is pending.
            await MainActor.run { availability.isAvailable = false }
        }
        let suggester = IssueWorktreeNameSuggester(engine: engine) { availability.isAvailable }

        let name = await suggester.suggestName(for: Self.source)

        #expect(name == nil)
        #expect(await engine.calls == 1)
    }

    private static let source = IssueSnapshot(
        identity: .init(providerID: .github, stableID: "github.com/acme/repo#42"),
        canonicalURL: URL(string: "https://github.com/acme/repo/issues/42")!,
        providerLabel: "GitHub",
        displayReference: "#42",
        repositoryLocator: nil,
        title: "Fix sync",
        body: "Offline edits conflict after reconnecting.",
        state: .open,
        labels: [],
        assignees: [],
        providerUpdatedAt: nil,
        capturedAt: .distantPast,
        refreshError: nil,
        contentOrigin: .provider,
        isEditable: false,
        isRefreshable: true
    )
}

@MainActor
private final class Availability {
    var isAvailable = true
}

private actor CannedEngine: LocalTextGenerating {
    let outcome: Result<String, LocalTextInferenceFailure>
    let beforeReturning: @Sendable () async -> Void
    private(set) var calls = 0

    init(
        outcome: Result<String, LocalTextInferenceFailure>,
        beforeReturning: @escaping @Sendable () async -> Void = {}
    ) {
        self.outcome = outcome
        self.beforeReturning = beforeReturning
    }

    func generate(_ request: LocalTextGenerationRequest, caller: LocalTextCaller,
                  priority: LocalTextJobPriority) async throws -> LocalTextGenerationResult {
        calls += 1
        await beforeReturning()
        return .init(text: try outcome.get(), selectedCandidateIndex: 0)
    }

    func cancel(caller: LocalTextCaller) async {}
    func cancelAndUnload() async {}
}
