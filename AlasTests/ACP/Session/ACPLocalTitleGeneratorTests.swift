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

    @Test func failedAppleAnswerDoesNotLoadLocalFallback() async {
        let engine = TitleEngine(outcome: .success("Local title"))
        let fallback = ACPQwenTitleFallback(engine: engine) { true }
        let title = await ACPLocalTitleGenerator.generate(
            from: "Fix the sign-in race",
            fallback: fallback,
            foundationModelAvailable: { true },
            foundationModel: { _ in nil }
        )
        #expect(title == nil)
        #expect(await engine.calls == 0)
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
    func revokingConsentCancelsAQwenTitleBeforeTheEngineRunsIt() async throws {
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
        try #require(await awaitCondition { availability.checks > 0 })

        // Consent is revoked after the availability check, possibly before the
        // job reaches the engine, where engine.cancel(caller:) would miss it.
        availability.isAvailable = false
        requests.cancelAll()

        #expect(await title.value == nil)
        #expect(await !engine.isRunning)
    }

    @Test @MainActor
    func cancellingATitleStopsWaitingForReadiness() async throws {
        let readiness = PendingReadiness()
        let engine = TitleEngine(outcome: .success("Fix sign-in race"))
        let fallback = ACPQwenTitleFallback(
            engine: engine,
            isAvailable: { true },
            waitForLocalTextReadiness: { await readiness.wait() }
        )
        let title = Task {
            defer { readiness.titleFinished = true }
            return await fallback.generate(from: "Fix the sign-in race")
        }
        try #require(await awaitCondition { readiness.isWaiting })

        title.cancel()

        #expect(await awaitCondition { readiness.titleFinished })
        readiness.open()
        #expect(await title.value == nil)
        #expect(await engine.calls == 0)
    }

    @Test @MainActor
    func concurrentTitlesQueueInsteadOfPreemptingEachOther() async throws {
        let availability = TitleAvailability()
        let engine = GatedTitleEngine()
        let fallback = ACPQwenTitleFallback(
            engine: engine,
            isAvailable: { availability.check() },
            requests: ACPQwenTitleRequests()
        )
        let first = Task { await fallback.generate(from: "Fix the sign-in race") }
        let second = Task { await fallback.generate(from: "Add dark mode support") }
        try #require(await awaitCondition { availability.scheduledJobs >= 2 })

        engine.releaseNext()
        try #require(await awaitCondition { engine.waitingCount == 1 })
        engine.releaseNext()

        #expect(await first.value == "Fix sign-in race")
        #expect(await second.value == "Fix sign-in race")
        #expect(engine.maxActive == 1)
    }

    @Test @MainActor
    func cancellingAQueuedTitleStopsWaitingForTheActiveOne() async throws {
        let availability = TitleAvailability()
        let engine = GatedTitleEngine()
        let fallback = ACPQwenTitleFallback(
            engine: engine,
            isAvailable: { availability.check() },
            requests: ACPQwenTitleRequests()
        )
        let active = Task { await fallback.generate(from: "Fix the sign-in race") }
        try #require(await awaitCondition { engine.waitingCount == 1 })
        let queued = Task {
            defer { availability.queuedFinished = true }
            return await fallback.generate(from: "Add dark mode support")
        }
        try #require(await awaitCondition { availability.scheduledJobs >= 2 })

        queued.cancel()

        #expect(await awaitCondition { availability.queuedFinished })
        #expect(engine.waitingCount == 1)
        engine.releaseNext()
        #expect(await active.value == "Fix sign-in race")
        #expect(await queued.value == nil)
    }

    @Test @MainActor
    func aCancelledQueuedTitleDoesNotLetTheNextOneJumpTheQueue() async throws {
        let availability = TitleAvailability()
        let engine = GatedTitleEngine()
        let fallback = ACPQwenTitleFallback(
            engine: engine,
            isAvailable: { availability.check() },
            requests: ACPQwenTitleRequests()
        )
        let running = Task { await fallback.generate(from: "Fix the sign-in race") }
        try #require(await awaitCondition { engine.waitingCount == 1 })
        let cancelled = Task { await fallback.generate(from: "Add dark mode support") }
        try #require(await awaitCondition { availability.scheduledJobs >= 2 })
        cancelled.cancel()
        #expect(await cancelled.value == nil)

        let next = Task { await fallback.generate(from: "Speed up the test suite") }
        try #require(await awaitCondition { availability.scheduledJobs >= 3 })

        #expect(engine.maxActive == 1)
        engine.releaseNext()
        try #require(await awaitCondition { engine.waitingCount == 1 })
        engine.releaseNext()
        #expect(await running.value == "Fix sign-in race")
        #expect(await next.value == "Fix sign-in race")
        #expect(engine.maxActive == 1)
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

/// Polls on the main actor until `condition` holds or the deadline passes, so a
/// regression fails the test instead of hanging the suite.
@MainActor
func awaitCondition(within timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

@MainActor
private final class TitleAvailability {
    var isAvailable = true
    var checks = 0
    var scheduledJobs = 0
    var queuedFinished = false

    /// A title schedules its engine job right after its availability check;
    /// this two-hop main-actor job runs only after that job, so tests can
    /// await `scheduledJobs` instead of yielding a guessed number of times.
    func check() -> Bool {
        checks += 1
        Task { @MainActor in Task { @MainActor in self.scheduledJobs += 1 } }
        return isAvailable
    }
}

/// Holds every call until released and records how many ran at once.
@MainActor
private final class GatedTitleEngine: LocalTextGenerating {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var active = 0
    private(set) var maxActive = 0
    var waitingCount: Int { waiting.count }

    func generate(_ request: LocalTextGenerationRequest, caller: LocalTextCaller,
                  priority: LocalTextJobPriority) async throws -> LocalTextGenerationResult {
        active += 1
        maxActive = max(maxActive, active)
        await withCheckedContinuation { waiting.append($0) }
        active -= 1
        return .init(text: "Fix sign-in race", selectedCandidateIndex: 0)
    }

    func releaseNext() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }

    func cancel(caller: LocalTextCaller) async {}
    func cancelAndUnload() async {}
}

/// Readiness that stays pending, like an inspection or install in progress.
@MainActor
private final class PendingReadiness {
    private var continuation: CheckedContinuation<Void, Never>?
    var titleFinished = false
    var isWaiting: Bool { continuation != nil }

    func wait() async { await withCheckedContinuation { continuation = $0 } }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

/// Suspends until its caller is cancelled, like the real engine's generation.
private actor SuspendingTitleEngine: LocalTextGenerating {
    private var suspended: CheckedContinuation<Void, Never>?
    var isRunning: Bool { suspended != nil }

    func generate(_ request: LocalTextGenerationRequest, caller: LocalTextCaller,
                  priority: LocalTextJobPriority) async throws -> LocalTextGenerationResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { suspended = continuation }
            }
        } onCancel: {
            Task { await self.resume() }
        }
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
