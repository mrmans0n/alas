import Combine
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("SessionSummaryCoordinator", .timeLimit(.minutes(1)))
struct SessionSummaryCoordinatorTests {
    @Test func synchronousActivityWinsAgainstCompletingGeneration() async {
        let fixture = SummaryCoordinatorFixture()
        fixture.coordinator.bind(to: fixture.session)
        let generation = fixture.start()
        await fixture.engine.waitUntilRequested()

        fixture.session.nextPromptActivity.send()
        await fixture.engine.complete(with: fixture.result)
        await generation.value

        #expect(fixture.coordinator.phase == .idle)
        #expect(fixture.coordinator.presentationGeneration == 1)
        #expect(await fixture.engine.cancelledCallers == [.sessionSummary(fixture.session.incarnation)])
    }

    @Test func loadingSubscriberActivityPreventsGenerationAndRestoresIdle() async {
        let fixture = SummaryCoordinatorFixture()
        fixture.coordinator.bind(to: fixture.session)
        var mutated = false
        let observation = fixture.coordinator.$phase.sink { phase in
            guard phase == .loading, !mutated else { return }
            mutated = true
            _ = fixture.session.allocatePromptID()
        }

        await fixture.coordinator.summary(for: fixture.session)

        #expect(fixture.coordinator.phase == .idle)
        #expect(await fixture.engine.requestCount == 0)
        withExtendedLifetime(observation) {}
    }

    @Test func resultSubscriberActivityCannotRestoreOrCacheStaleResult() async {
        let fixture = SummaryCoordinatorFixture()
        fixture.coordinator.bind(to: fixture.session)
        var mutated = false
        let observation = fixture.coordinator.$phase.sink { phase in
            guard case .result = phase, !mutated else { return }
            mutated = true
            _ = fixture.session.allocatePromptID()
        }
        let generation = fixture.start()
        await fixture.engine.waitUntilRequested()

        await fixture.engine.complete(with: fixture.result)
        await generation.value

        #expect(fixture.coordinator.phase == .idle)
        await fixture.engine.enqueue(fixture.result)
        await fixture.coordinator.summary(for: fixture.session)
        #expect(await fixture.engine.requestCount == 2)
        withExtendedLifetime(observation) {}
    }

    @Test func failureSubscriberActivityCannotRestoreStaleError() async {
        let fixture = SummaryCoordinatorFixture()
        fixture.coordinator.bind(to: fixture.session)
        var mutated = false
        let observation = fixture.coordinator.$phase.sink { phase in
            guard case .failed = phase, !mutated else { return }
            mutated = true
            _ = fixture.session.allocatePromptID()
        }
        let generation = fixture.start()
        await fixture.engine.waitUntilRequested()

        await fixture.engine.fail(with: LocalTextInferenceFailure.unavailable)
        await generation.value

        #expect(fixture.coordinator.phase == .idle)
        withExtendedLifetime(observation) {}
    }

    @Test func reopensCurrentIncarnationFromMemoryWithoutGeneratingAgain() async {
        let fixture = SummaryCoordinatorFixture()
        await fixture.finishSummary()

        await fixture.coordinator.summary(for: fixture.session)

        #expect(fixture.coordinator.phase == .result(fixture.summary))
        #expect(await fixture.engine.requestCount == 1)
    }

    @Test func replacementIncarnationCannotReusePersistedSessionIDCache() async {
        let fixture = SummaryCoordinatorFixture()
        await fixture.finishSummary()
        let replacement = fixture.makeSession(id: fixture.session.id)

        fixture.coordinator.bind(to: replacement)
        let generation = Task { await fixture.coordinator.summary(for: replacement) }
        await fixture.engine.waitUntilRequested(count: 2)

        #expect(await fixture.engine.callers == [
            .sessionSummary(fixture.session.incarnation),
            .sessionSummary(replacement.incarnation)
        ])
        await fixture.engine.complete(with: fixture.result)
        await generation.value
    }

    @Test(arguments: [
        "transcript", "goal", "plan", "agent", "hydration", "stream", "composer", "queue",
        "queue persistence", "permission", "question", "pending plan", "user input", "url elicitation",
        "work", "delegated", "subagent", "retry", "recovery", "auto-run"
    ])
    func sourceChangesRejectStaleCompletion(_ change: String) async {
        let fixture = SummaryCoordinatorFixture()
        fixture.coordinator.bind(to: fixture.session)
        let generation = fixture.start()
        await fixture.engine.waitUntilRequested()

        fixture.mutate(change)
        await fixture.engine.complete(with: fixture.result)
        await generation.value

        #expect(fixture.coordinator.phase == .idle)
    }

    @Test func closingPopoverCancelsUnfinishedCallerWithoutClearingValidCache() async {
        let fixture = SummaryCoordinatorFixture()
        fixture.coordinator.bind(to: fixture.session)
        let unfinished = fixture.start()
        await fixture.engine.waitUntilRequested()

        fixture.coordinator.cancelPresentation()
        await unfinished.value
        #expect(fixture.coordinator.phase == .idle)
        #expect(await fixture.engine.cancelledCallers == [.sessionSummary(fixture.session.incarnation)])

        await fixture.finishSummary(requestCount: 2)
        fixture.coordinator.cancelPresentation()
        await fixture.coordinator.summary(for: fixture.session)

        #expect(fixture.coordinator.phase == .result(fixture.summary))
        #expect(await fixture.engine.requestCount == 2)
    }

    @Test func refreshFailureKeepsPreviousSummaryAndShowsError() async {
        let fixture = SummaryCoordinatorFixture()
        await fixture.finishSummary()
        let refresh = Task { await fixture.coordinator.refresh(fixture.session) }
        await fixture.engine.waitUntilRequested(count: 2)

        await fixture.engine.fail(with: LocalTextInferenceFailure.unavailable)
        await refresh.value

        guard case .failed(let message, let previous) = fixture.coordinator.phase else {
            Issue.record("Expected a failed phase")
            return
        }
        #expect(message == "The on-device model is unavailable.")
        #expect(previous == fixture.summary)
    }

    @Test func firstFailureShowsErrorWithoutEmptyResult() async {
        let fixture = SummaryCoordinatorFixture()
        fixture.coordinator.bind(to: fixture.session)
        let generation = fixture.start()
        await fixture.engine.waitUntilRequested()

        await fixture.engine.fail(with: LocalTextInferenceFailure.generationFailed)
        await generation.value

        guard case .failed(let message, let previous) = fixture.coordinator.phase else {
            Issue.record("Expected a failed phase")
            return
        }
        #expect(message == "Alas could not generate a session summary.")
        #expect(previous == nil)
    }

    @Test func teardownCancelsObserversGenerationAndCache() async {
        let fixture = SummaryCoordinatorFixture()
        await fixture.finishSummary()
        let refresh = Task { await fixture.coordinator.refresh(fixture.session) }
        await fixture.engine.waitUntilRequested(count: 2)

        fixture.coordinator.teardown()
        await refresh.value
        let generationAfterTeardown = fixture.coordinator.presentationGeneration
        fixture.session.nextPromptActivity.send()
        #expect(fixture.coordinator.presentationGeneration == generationAfterTeardown)

        fixture.coordinator.bind(to: fixture.session)
        let regenerated = fixture.start()
        await fixture.engine.waitUntilRequested(count: 3)
        await fixture.engine.complete(with: fixture.result)
        await regenerated.value
        #expect(await fixture.engine.requestCount == 3)
    }

    @Test func submitsBoundedUserInitiatedRequestAndMarksFallbackCandidatePartial() async throws {
        let fixture = SummaryCoordinatorFixture()
        fixture.coordinator.bind(to: fixture.session)
        let generation = fixture.start()
        await fixture.engine.waitUntilRequested()
        let request = try #require(await fixture.engine.lastRequest)

        #expect(request.inputTokenLimit == 8_192)
        #expect(request.maxTokens == 512)
        #expect(request.temperature == 0)
        #expect(request.prefillStepSize == 512)
        #expect(request.timeout == .seconds(30))
        #expect(await fixture.engine.priorities == [.userInitiated])

        await fixture.engine.complete(with: .init(text: fixture.result.text, selectedCandidateIndex: 1))
        await generation.value
        guard case .result(let summary) = fixture.coordinator.phase else {
            Issue.record("Expected a result")
            return
        }
        #expect(summary.isPartial)
    }

    @Test func missingContextFailsLocallyWithoutCallingEngine() async {
        let engine = SessionSummaryEngine()
        let coordinator = SessionSummaryCoordinator(engine: engine)
        let session = ACPSession(id: "empty", agentId: "codex", worktreeId: "w", title: "Empty")
        session.agentState = .ready
        coordinator.bind(to: session)

        await coordinator.summary(for: session)

        guard case .failed(let message, let previous) = coordinator.phase else {
            Issue.record("Expected a failed phase")
            return
        }
        #expect(message == "There is not enough idle session context to summarize.")
        #expect(previous == nil)
        #expect(await engine.requestCount == 0)
    }
}

@MainActor
private final class SummaryCoordinatorFixture {
    let engine = SessionSummaryEngine()
    lazy var coordinator = SessionSummaryCoordinator(engine: engine)
    lazy var session = makeSession(id: "summary-session")
    let result = LocalTextGenerationResult(
        text: #"{"goal":"Ship search","completed":[],"blockers":[],"next_action":"Run tests"}"#,
        selectedCandidateIndex: 0
    )
    let summary = SessionSummary(
        goal: "Ship search", completed: [], blockers: [], nextAction: "Run tests", isPartial: false
    )

    func makeSession(id: String) -> ACPSession {
        let session = ACPSession(id: id, agentId: "codex", worktreeId: "worktree", title: "Test")
        session.agentState = .ready
        _ = session.recordUserPrompt(text: "Implement search", attachments: [])
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("Search now works.")))
        return session
    }

    func start() -> Task<Void, Never> {
        Task { await coordinator.summary(for: session) }
    }

    func finishSummary(requestCount: Int = 1) async {
        coordinator.bind(to: session)
        let generation = start()
        await engine.waitUntilRequested(count: requestCount)
        await engine.complete(with: result)
        await generation.value
    }

    func mutate(_ change: String) {
        switch change {
        case "transcript":
            session.transcript.appendMessage(.systemNotice(id: UUID(), text: "changed"))
        case "goal":
            session.currentGoal = .init(objective: "A new goal", status: "active", tokenBudget: nil)
        case "plan":
            session.transcript.appendMessage(.plan(id: UUID(), [.init(content: "New plan", status: "pending")]))
        case "agent": session.agentState = .disconnected
        case "hydration": session.hydrationState = .loading
        case "stream": session.transcript.streamingState = .streaming
        case "composer": session.composer.replaceDraft(.init(segments: [.text("draft")]))
        case "queue": session.enqueue(blocks: [.text("queued")])
        case "queue persistence": session.pendingQueuePersistenceCount += 1
        case "permission":
            session.transcript.pendingPermission = .init(
                id: .string("permission"),
                params: .init(sessionId: session.id, toolCall: .init(toolCallId: "tool"), options: [])
            )
        case "question":
            session.transcript.pendingQuestion = .init(
                id: .string("question"),
                params: .init(toolCallId: "tool", title: nil, questions: [])
            )
        case "pending plan":
            session.transcript.pendingPlan = .init(
                id: .string("plan"),
                params: .init(toolCallId: "tool", name: "Plan", overview: "", plan: "Plan", todos: [],
                              isProject: false, phases: [])
            )
        case "user input":
            session.transcript.pendingUserInputs = [.cursor(.init(
                id: .string("input"),
                params: .init(toolCallId: "tool", title: nil, questions: [])
            ))]
        case "url elicitation":
            session.transcript.urlElicitationWaits = [.init(
                id: "url", requestId: UUID(), message: "Open", url: URL(string: "https://example.com")!
            )]
        case "work": session.nextPromptWorkCount += 1
        case "delegated": session.hasPendingDelegatedMessages = true
        case "subagent": session.registerSubagent(.init(subagentSessionId: "child"))
        case "retry":
            session.apply(.sessionInfoUpdate(.init(title: nil, metadata: AnyCodable([
                "codex": AnyCodable(["error": AnyCodable(["willRetry": AnyCodable(true)])])
            ]))))
        case "recovery": _ = session.beginConnectionRecovery()
        default: session.autoRunEnabled = true
        }
    }
}

private actor SessionSummaryEngine: LocalTextGenerating {
    private var requests: [LocalTextGenerationRequest] = []
    private var requestCallers: [LocalTextCaller] = []
    private var requestPriorities: [LocalTextJobPriority] = []
    private var cancellations: [LocalTextCaller] = []
    private var pending: [(LocalTextCaller, CheckedContinuation<LocalTextGenerationResult, Error>)] = []
    private var queuedResults: [LocalTextGenerationResult] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var requestCount: Int { requests.count }
    var lastRequest: LocalTextGenerationRequest? { requests.last }
    var callers: [LocalTextCaller] { requestCallers }
    var priorities: [LocalTextJobPriority] { requestPriorities }
    var cancelledCallers: [LocalTextCaller] { cancellations }

    func generate(
        _ request: LocalTextGenerationRequest,
        caller: LocalTextCaller,
        priority: LocalTextJobPriority
    ) async throws -> LocalTextGenerationResult {
        requests.append(request)
        requestCallers.append(caller)
        requestPriorities.append(priority)
        for (count, waiter) in waiters where requests.count >= count { waiter.resume() }
        waiters.removeAll { requests.count >= $0.0 }
        if !queuedResults.isEmpty { return queuedResults.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((caller, continuation))
        }
    }

    func waitUntilRequested(count: Int = 1) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(with result: LocalTextGenerationResult) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().1.resume(returning: result)
    }

    func enqueue(_ result: LocalTextGenerationResult) {
        queuedResults.append(result)
    }

    func fail(with error: Error) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().1.resume(throwing: error)
    }

    func cancel(caller: LocalTextCaller) {
        cancellations.append(caller)
        guard let index = pending.firstIndex(where: { $0.0 == caller }) else { return }
        pending.remove(at: index).1.resume(throwing: LocalTextInferenceFailure.cancelled)
    }

    func cancelAndUnload() async {}
}
