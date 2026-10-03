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
    func appleIntelligenceWinsWhenAvailable() async {
        let availability = Availability()
        let apple = CannedAppleGenerator(output: #"{"name": "apple-generated-name"}"#)
        let engine = CannedEngine(outcome: .success(#"{"name": "mlx-generated-name"}"#))
        let suggester = IssueWorktreeNameSuggester(
            engine: engine,
            isAppleIntelligenceAvailable: { availability.isAppleAvailable },
            generateWithAppleIntelligence: { request in await apple.generate(request) },
            isMLXAvailable: { availability.isMLXAvailable }
        )

        let name = await suggester.suggestName(for: Self.source)

        #expect(name == "apple-generated-name")
        #expect(await apple.calls == 1)
        #expect(await engine.calls == 0)
    }

    @Test(arguments: [
        // Apple unavailable, Apple generation failed, and Apple returned an invalid payload.
        (false, #"{"name": "unused-apple-name"}"# as String?, 0),
        (true, nil, 1),
        (true, "not json", 1),
    ])
    @MainActor
    func appleFailureFallsThroughToMLX(
        appleAvailable: Bool,
        appleOutput: String?,
        expectedAppleCalls: Int
    ) async {
        let availability = Availability()
        availability.isAppleAvailable = appleAvailable
        let apple = CannedAppleGenerator(output: appleOutput)
        let engine = CannedEngine(outcome: .success(#"{"name": "mlx-generated-name"}"#))
        let suggester = IssueWorktreeNameSuggester(
            engine: engine,
            isAppleIntelligenceAvailable: { availability.isAppleAvailable },
            generateWithAppleIntelligence: { request in await apple.generate(request) },
            isMLXAvailable: { availability.isMLXAvailable }
        )

        let name = await suggester.suggestName(for: Self.source)

        #expect(name == "mlx-generated-name")
        #expect(await apple.calls == expectedAppleCalls)
        #expect(await engine.calls == 1)
    }

    @Test @MainActor
    func appleTimeoutReachesMLXWhileGenerationIsStillSuspended() async {
        let gate = GenerationGate()
        let engine = CannedEngine(outcome: .success(#"{"name": "mlx-generated-name"}"#))
        let suggester = IssueWorktreeNameSuggester(
            engine: engine,
            isAppleIntelligenceAvailable: { true },
            generateWithAppleIntelligence: { _ in
                await gate.wait()
                return nil
            },
            isMLXAvailable: { true },
            timeout: .milliseconds(20)
        )
        let suggestion = Task { await suggester.suggestName(for: Self.source) }
        await gate.waitUntilStarted()

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await engine.calls == 0 && ContinuousClock.now < deadline {
            await Task.yield()
        }
        let reachedMLXBeforeRelease = await engine.calls == 1
        await gate.release()

        #expect(reachedMLXBeforeRelease)
        #expect(await suggestion.value == "mlx-generated-name")
    }

    @Test @MainActor
    func unavailableBackendsLeaveTheDeterministicSeedUnchanged() async {
        let availability = Availability()
        availability.isAppleAvailable = false
        availability.isMLXAvailable = false
        let apple = CannedAppleGenerator(output: #"{"name": "unused-apple-name"}"#)
        let engine = CannedEngine(outcome: .success(#"{"name": "unused-mlx-name"}"#))
        let suggester = IssueWorktreeNameSuggester(
            engine: engine,
            isAppleIntelligenceAvailable: { availability.isAppleAvailable },
            generateWithAppleIntelligence: { request in await apple.generate(request) },
            isMLXAvailable: { availability.isMLXAvailable }
        )

        let name = await suggester.suggestName(for: Self.source)

        #expect(name == nil)
        #expect(await apple.calls == 0)
        #expect(await engine.calls == 0)
    }

    @Test(arguments: [SuggestionBackend.apple, .mlx])
    @MainActor
    func availabilityRevokedDuringGenerationDiscardsTheLateResult(backend: SuggestionBackend) async {
        let availability = Availability()
        availability.isAppleAvailable = backend == .apple
        availability.isMLXAvailable = backend == .mlx
        let apple = CannedAppleGenerator(output: #"{"name": "late-apple-name"}"#) {
            if backend == .apple {
                await MainActor.run { availability.isAppleAvailable = false }
            }
        }
        let engine = CannedEngine(outcome: .success(#"{"name": "late-mlx-name"}"#)) {
            if backend == .mlx {
                await MainActor.run { availability.isMLXAvailable = false }
            }
        }
        let suggester = IssueWorktreeNameSuggester(
            engine: engine,
            isAppleIntelligenceAvailable: { availability.isAppleAvailable },
            generateWithAppleIntelligence: { request in await apple.generate(request) },
            isMLXAvailable: { availability.isMLXAvailable }
        )

        let name = await suggester.suggestName(for: Self.source)

        #expect(name == nil)
        #expect(await apple.calls == (backend == .apple ? 1 : 0))
        #expect(await engine.calls == (backend == .mlx ? 1 : 0))
    }

    @Test(arguments: [SuggestionBackend.apple, .mlx])
    @MainActor
    func cancellingOwnedNamesDiscardsOldResultsWithoutCancellingNewRequests(
        backend: SuggestionBackend
    ) async {
        let requests = IssueWorktreeNameRequests()
        let gate = GenerationGate()
        let engine = CannedEngine(outcome: .success(#"{"name":"old-name"}"#)) { await gate.wait() }
        let oldSuggester = IssueWorktreeNameSuggester(
            engine: engine,
            isAppleIntelligenceAvailable: { backend == .apple },
            generateWithAppleIntelligence: { _ in
                await gate.wait()
                return #"{"name":"old-name"}"#
            },
            isMLXAvailable: { backend == .mlx },
            requests: requests
        )
        let old = Task { await oldSuggester.suggestName(for: Self.source) }
        await gate.waitUntilStarted()
        requests.cancelAll()
        let fresh = IssueWorktreeNameSuggester(
            engine: CannedEngine(outcome: .success(#"{"name":"new-name"}"#)),
            isMLXAvailable: { true }, requests: requests
        )
        #expect(await fresh.suggestName(for: Self.source) == "new-name")
        await gate.release()
        #expect(await old.value == nil)
    }

    /// The attach sheet lets the user edit the title before confirming; the
    /// prewarmed name only stands for the inputs it was computed from.
    @Test(arguments: [
        ("Fix sync", IssueWorktreeNamePrewarm.Handover.ready("offline-conflicts")),
        ("Fix sync on reconnect", nil),
    ])
    @MainActor
    func prewarmHandsOverOnlyANameForTheSameTicketInputs(
        attachedTitle: String, expected: IssueWorktreeNamePrewarm.Handover?
    ) async {
        let prewarm = IssueWorktreeNamePrewarm()
        let first = prewarm.start(for: Self.source) { _ in "offline-conflicts" }
        let second = prewarm.start(for: Self.source) { _ in "second-request" }
        _ = await first.value

        #expect(first == second)
        #expect(prewarm.take(for: Self.snapshot(title: attachedTitle)) == expected)
        #expect(prewarm.take(for: Self.source) == nil)
    }

    private static let source = snapshot(title: "Fix sync")

    private static func snapshot(title: String) -> IssueSnapshot {
        IssueSnapshot(
            identity: .init(providerID: .github, stableID: "github.com/acme/repo#42"),
            canonicalURL: URL(string: "https://github.com/acme/repo/issues/42")!,
            providerLabel: "GitHub",
            displayReference: "#42",
            repositoryLocator: nil,
            title: title,
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
}

@MainActor
private final class Availability {
    var isAppleAvailable = true
    var isMLXAvailable = true
}

enum SuggestionBackend: Sendable {
    case apple
    case mlx
}

private actor CannedAppleGenerator {
    let output: String?
    let beforeReturning: @Sendable () async -> Void
    private(set) var calls = 0

    init(output: String?, beforeReturning: @escaping @Sendable () async -> Void = {}) {
        self.output = output
        self.beforeReturning = beforeReturning
    }

    func generate(_ request: LocalTextGenerationRequest) async -> String? {
        calls += 1
        await beforeReturning()
        return output
    }
}

actor GenerationGate {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
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
