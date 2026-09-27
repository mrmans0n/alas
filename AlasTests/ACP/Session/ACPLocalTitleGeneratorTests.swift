import Testing
@testable import Alas

@Suite("ACP local title generator")
struct ACPLocalTitleGeneratorTests {
    @Test("the first user request excludes injected context, markup, attachments and code")
    func extractsFirstProse() {
        let prompt = """
            <alas-workspace-context>
            internal workspace and credentials
            </alas-workspace-context>
            <metadata>
            internal task description
            </metadata>
            [Attachment: screenshot.png]
            ```swift
            let token = "hidden"
            ```
            Please fix the sign-in flow
            without losing saved accounts.

            Later, also add an export feature.
            """
        #expect(ACPLocalTitleGenerator.candidate(from: prompt) ==
            "Please fix the sign-in flow without losing saved accounts.")
        #expect(ACPLocalTitleGenerator.candidate(from: "<alas-workspace-context>private") == nil)
        #expect(ACPLocalTitleGenerator.candidate(from: "\n```swift\nlet a = 1\n```\n") == nil)
        #expect(ACPLocalTitleGenerator.candidate(from: "Hi") == nil)
        #expect(ACPLocalTitleGenerator.candidate(from: "Fix login") == "Fix login")
        #expect(ACPLocalTitleGenerator.candidate(from: "Fix the login") == "Fix the login")
    }
    @Test("the candidate is bounded before reaching the model")
    func boundsCandidate() {
        let candidate = ACPLocalTitleGenerator.candidate(from: String(repeating: "longword ", count: 250))
        #expect(candidate?.count == 1_000)
    }

    @Test("only a short, plain-language title is accepted")
    func validatesTitles() {
        #expect(ACPLocalTitleGenerator.validTitle("  Fix sign-in race  ") == "Fix sign-in race")
        for invalid in [
            " ", "123", "First line\nSecond line", "First\u{2028}Second",
            "one two three four five six seven eight", String(repeating: "a", count: 61),
            "`fix`", "# Sign-in fix", "- Sign-in fix", "func login() {}",
            "https://example.com", "./Sources/Login.swift", "<title>Login</title>"
        ] {
            #expect(ACPLocalTitleGenerator.validTitle(invalid) == nil)
        }
    }
}

@Suite("ACP local title routing")
struct ACPLocalTitleRoutingTests {
    @Test(arguments: [
        // Foundation Models wins whenever it is available; Qwen is never loaded.
        (true, true, Result<String, LocalTextInferenceFailure>.success("Qwen title"), "Apple title", 0),
        (false, true, .success("  Fix sign-in race  "), "Fix sign-in race", 1),
        (false, true, .success("func login() {}"), nil, 1),
        (false, true, .failure(.timedOut), nil, 1),
        (false, true, .failure(.preempted), nil, 1),
        (false, false, .success("Qwen title"), nil, 0),
    ] as [(Bool, Bool, Result<String, LocalTextInferenceFailure>, String?, Int)])
    func prefersFoundationModelsAndFallsBackToAnInstalledQwen(
        appleAvailable: Bool,
        qwenAvailable: Bool,
        outcome: Result<String, LocalTextInferenceFailure>,
        expected: String?,
        expectedEngineCalls: Int
    ) async {
        let engine = TitleEngine(outcome: outcome)
        let fallback = ACPQwenTitleFallback(engine: engine) { qwenAvailable }

        let title = await ACPLocalTitleGenerator.generate(
            from: "Fix the sign-in race",
            fallback: fallback,
            foundationModelAvailable: { appleAvailable },
            foundationModel: { _ in "Apple title" }
        )

        #expect(title == expected)
        #expect(await engine.calls == expectedEngineCalls)
    }

    @Test @MainActor
    func waitsForLocalTextReadinessBeforeCheckingQwenAvailability() async {
        let availability = TitleAvailability()
        availability.isAvailable = false
        let engine = TitleEngine(outcome: .success("Fix sign-in race"))
        let fallback = ACPQwenTitleFallback(
            engine: engine,
            isAvailable: { availability.isAvailable },
            waitForLocalTextReadiness: { availability.isAvailable = true }
        )

        let title = await ACPLocalTitleGenerator.generate(
            from: "Fix the sign-in race",
            fallback: fallback,
            foundationModelAvailable: { false },
            foundationModel: { _ in nil }
        )

        #expect(title == "Fix sign-in race")
    }

    @Test @MainActor
    func revokingConsentCancelsAQwenTitleBeforeTheEngineRunsIt() async {
        let availability = TitleAvailability()
        let requests = ACPQwenTitleRequests()
        let engine = SuspendingTitleEngine()
        let fallback = ACPQwenTitleFallback(
            engine: engine,
            isAvailable: {
                availability.checks += 1
                return availability.isAvailable
            },
            requests: requests
        )
        let title = Task { await fallback.generate(from: "Fix the sign-in race") }
        while availability.checks == 0 { await Task.yield() }

        // Consent is revoked after the availability check, possibly before the
        // job reaches the engine, where engine.cancel(caller:) would miss it.
        availability.isAvailable = false
        requests.cancelAll()

        #expect(await title.value == nil)
        #expect(await engine.observedCancellation)
    }

    @Test @MainActor
    func revokedConsentDiscardsALateQwenTitle() async {
        let availability = TitleAvailability()
        let engine = TitleEngine(outcome: .success("Fix sign-in race")) {
            await MainActor.run { availability.isAvailable = false }
        }
        let fallback = ACPQwenTitleFallback(engine: engine) { availability.isAvailable }

        let title = await ACPLocalTitleGenerator.generate(
            from: "Fix the sign-in race",
            fallback: fallback,
            foundationModelAvailable: { false },
            foundationModel: { _ in nil }
        )

        #expect(title == nil)
        #expect(await engine.calls == 1)
    }
}

@MainActor
private final class TitleAvailability {
    var isAvailable = true
    var checks = 0
}

/// Suspends until its caller is cancelled, like the real engine's generation.
private actor SuspendingTitleEngine: LocalTextGenerating {
    private(set) var observedCancellation = false
    private var suspended: CheckedContinuation<Void, Never>?

    func generate(_ request: LocalTextGenerationRequest, caller: LocalTextCaller,
                  priority: LocalTextJobPriority) async throws -> LocalTextGenerationResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { suspended = continuation }
            }
        } onCancel: {
            Task { await self.resume() }
        }
        observedCancellation = true
        throw LocalTextInferenceFailure.cancelled
    }

    private func resume() {
        suspended?.resume()
        suspended = nil
    }

    func cancel(caller: LocalTextCaller) async {}
    func cancelAndUnload() async {}
}

private actor TitleEngine: LocalTextGenerating {
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
