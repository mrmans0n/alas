import Foundation
import Observation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct SessionSummarySettingsTests {
    @Test func failedDisableSaveKeepsRuntimeOffUntilRetryPersists() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let store = SummarySettingsStore(configEnabled: true, saveResults: [false, true])
        let state = makeState(fixture, store)
        state.sessionSummariesRuntimeEnabled = true

        await state.disableSessionSummaries()

        #expect(!state.sessionSummariesRuntimeEnabled)
        #expect(state.config.sessionSummariesEnabled)
        #expect(state.sessionSummaryDisableSavePending)

        await state.retrySessionSummarySettings()

        #expect(!state.config.sessionSummariesEnabled)
        #expect(!state.sessionSummaryDisableSavePending)
        await state.shutdownLocalTextFeatures()
    }

    @Test func enablingSummaryUsesReadySharedInstallationWithoutDownloading() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let state = makeState(fixture, SummarySettingsStore())

        await state.enableSessionSummaries()

        #expect(state.sessionSummariesRuntimeEnabled)
        #expect(state.localTextModelState == .ready)
        #expect(fixture.transport.requestCount == 0)
        await state.shutdownLocalTextFeatures()
    }

    @Test func staleDownloadCancellationKeepsReadyFeaturesRunning() async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        let persistence = SummarySettingsStore(configEnabled: true)
        persistence.config.nextPromptSuggestionsEnabled = true
        let state = makeState(fixture, persistence, modelEnabled: false)
        await state.downloadLocalTextModel()
        try #require(state.sessionSummariesRuntimeEnabled && state.nextPromptRuntimeEnabled)

        await state.cancelLocalTextDownload()

        #expect(state.localTextModelAvailable)
        #expect(state.sessionSummariesRuntimeEnabled && state.nextPromptRuntimeEnabled)
        await state.shutdownLocalTextFeatures()
    }

    @Test(arguments: [
        LocalTextModelState.notInstalled,
        .failed(.filesystem)
    ])
    func staleDownloadReadCannotReplaceNewerState(
        _ newerState: LocalTextModelState
    ) async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        let gate = LocalTextModelStateReadGate()
        let persistence = SummarySettingsStore(configEnabled: true)
        let state = makeState(fixture, persistence,
            readModelState: { await gate.read(fixture.store) }, modelEnabled: false)
        let download = Task { await state.downloadLocalTextModel() }
        try await fixture.waitForInstallation { await gate.entered }
        let modelObserver = state.localTextObservers.tasks.first
        modelObserver?.cancel()
        await modelObserver?.value
        state.updateLocalTextModelState(newerState)

        await gate.open()
        await download.value

        #expect(state.localTextModelState == newerState)
        #expect(!state.sessionSummariesRuntimeEnabled)
        await state.shutdownLocalTextFeatures()
    }

    @Test func acceptedDownloadSurvivesFeatureDisableAndEnablesFallback() async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        let gate = LocalTextModelStateReadGate()
        let persistence = SummarySettingsStore(configEnabled: true)
        persistence.config.nextPromptSuggestionsEnabled = true
        let state = makeState(fixture, persistence,
            readModelState: { await gate.read(fixture.store) },
            engine: SettingsFeatureEngine(), modelEnabled: false)
        let download = Task { await state.downloadLocalTextModel() }
        try await fixture.waitForInstallation { await gate.entered }
        await state.disableNextPromptSuggestions()
        await state.disableSessionSummaries()
        await gate.open()
        await download.value
        let title = await state.makeQwenTitleFallback().generate(from: "Fix the sign-in race")
        #expect(title == "Fix sign-in race")
        #expect(!state.config.nextPromptSuggestionsEnabled)
        #expect(!state.config.sessionSummariesEnabled)
        #expect(fixture.transport.requestCount == fixture.manifest.assets.count)
        await state.shutdownLocalTextFeatures()
    }

    @Test func disablingWorktreeHelpersCancelsExplanationWithoutDiscardingCache() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let state = makeState(fixture, SummarySettingsStore())
        let probe = WorktreeExplainerGenerationProbe()
        let store = WorktreeExplainerStore { await probe.generate($0) }
        state.worktreeExplainerStore = store
        let evidence = WorktreeExplainerEvidence(branch: "fix-sidebar", issueTitle: nil)
        let cached = Task { await store.prepare(worktreeID: "cached", evidence: evidence) }
        await probe.waitForCallCount(1)
        await probe.finishNext(with: "Preserve cached explanation")
        #expect(await cached.value)

        let active = Task { await store.prepare(worktreeID: "active", evidence: evidence) }
        await probe.waitForCallCount(2)
        state.setIssueWorktreeNameSuggestionsEnabled(false)
        await probe.finishNext(with: "Discard cancelled explanation")
        try #require(!(await active.value))
        #expect(await probe.cancelledCallCount == 1)
        #expect(store.explanation(for: "active", evidence: evidence) == nil)
        #expect(store.explanation(for: "cached", evidence: evidence) == "Preserve cached explanation")

        state.setIssueWorktreeNameSuggestionsEnabled(true)
        let retry = Task { await store.prepare(worktreeID: "active", evidence: evidence) }
        await probe.waitForCallCount(3)
        await probe.finishNext(with: "Keep fresh explanation")
        #expect(await retry.value)
        #expect(store.explanation(for: "active", evidence: evidence) == "Keep fresh explanation")
        await state.shutdownLocalTextFeatures()
    }

    @Test func disablingSummaryLeavesSuggestionsEnabled() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let state = makeState(fixture, SummarySettingsStore())
        await state.enableNextPromptSuggestions()
        await state.enableSessionSummaries()

        await state.disableSessionSummaries()

        #expect(!state.sessionSummariesRuntimeEnabled)
        #expect(!state.config.sessionSummariesEnabled)
        #expect(state.nextPromptRuntimeEnabled)
        #expect(state.config.nextPromptSuggestionsEnabled)
        await state.shutdownLocalTextFeatures()
    }

    @Test func disablingSummaryCancelsOnlySummaryWork() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let engine = SettingsFeatureEngine()
        let state = makeState(fixture, SummarySettingsStore(), engine: engine)
        await state.enableNextPromptSuggestions()
        await state.enableSessionSummaries()
        await engine.resetEvents()
        let session = ACPSession(id: "summary", agentId: "test", worktreeId: "w", title: "Summary")
        session.agentState = .ready
        _ = session.recordUserPrompt(text: "Implement search", attachments: [])
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("Search is implemented.")))
        let summary = Task { await state.sessionSummaryCoordinator.summary(for: session) }
        await engine.waitUntilSummaryStarted()

        await state.disableSessionSummaries()
        await summary.value
        let nextPromptResult = try await engine.generate(
            .init(
                messageCandidates: [[.init(role: .user, content: "Suggest the next prompt")]],
                inputTokenLimit: 128,
                maxTokens: 32,
                temperature: 0,
                prefillStepSize: 32,
                timeout: .seconds(1)
            ),
            caller: .nextPrompt,
            priority: .automatic
        )

        #expect(await engine.cancelledCallers == [.sessionSummary(session.incarnation)])
        #expect(await engine.callers == [.sessionSummary(session.incarnation), .nextPrompt])
        #expect(nextPromptResult.text == #"{"suggestion":"Show an example."}"#)
        #expect(state.nextPromptRuntimeEnabled)
        await state.shutdownLocalTextFeatures()
    }

    @Test(arguments: ["enable", "retry"])
    func nextPromptResetDoesNotCancelActiveSummary(_ action: String) async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let engine = SettingsFeatureEngine()
        let state = makeState(fixture, SummarySettingsStore(), engine: engine)
        await state.enableSessionSummaries()
        if action == "retry" { await state.enableNextPromptSuggestions() }
        await engine.resetEvents()
        let session = ACPSession(id: "summary", agentId: "test", worktreeId: "w", title: "Summary")
        session.agentState = .ready
        _ = session.recordUserPrompt(text: "Implement search", attachments: [])
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("Search is implemented.")))
        let summary = Task { await state.sessionSummaryCoordinator.summary(for: session) }
        await engine.waitUntilSummaryStarted()

        if action == "enable" {
            await state.enableNextPromptSuggestions()
        } else {
            await state.retryNextPromptSuggestions()
        }

        #expect(await engine.hasActiveSummary)
        #expect(await engine.cancelledCallers == [.nextPrompt])
        #expect(await engine.unloadCount == 0)
        await engine.completeSummary()
        await summary.value
        guard case .result = state.sessionSummaryCoordinator.phase else {
            Issue.record("Expected active summary to complete after next-prompt reset")
            return
        }
        await state.shutdownLocalTextFeatures()
    }

    @Test func disablingSuggestionLeavesSummaryRuntimeEnabled() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let engine = SummaryCacheEngine()
        let state = makeState(fixture, SummarySettingsStore(), engine: engine)
        await state.enableSessionSummaries()
        await state.enableNextPromptSuggestions()
        let session = ACPSession(id: "cached", agentId: "test", worktreeId: "w", title: "Cached")
        session.agentState = .ready
        _ = session.recordUserPrompt(text: "Implement search", attachments: [])
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("Search is implemented.")))
        await state.sessionSummaryCoordinator.summary(for: session)

        await state.disableNextPromptSuggestions()
        await state.sessionSummaryCoordinator.summary(for: session)

        #expect(state.sessionSummariesRuntimeEnabled)
        #expect(state.config.sessionSummariesEnabled)
        #expect(!state.nextPromptRuntimeEnabled)
        #expect(await engine.summaryRequests == 1)
        guard case .result = state.sessionSummaryCoordinator.phase else {
            Issue.record("Expected cached summary after disabling suggestions")
            return
        }
        await state.shutdownLocalTextFeatures()
    }

    @Test(arguments: ["enable next", "enable summary", "retry disable", "enable model"])
    func removalExcludesConcurrentSettingChanges(_ action: String) async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let engine = SuspendedRemovalEngine()
        let state = makeState(fixture, SummarySettingsStore(), engine: engine)
        await state.inspectLocalTextModel()
        state.localTextRuntimeStarted = true
        if action == "retry disable" { state.nextPromptDisableSavePending = true }
        let removal = Task { await state.removeLocalTextModel() }
        await engine.waitUntilUnloading()

        switch action {
        case "enable next": await state.enableNextPromptSuggestions()
        case "enable summary": await state.enableSessionSummaries()
        case "enable model": await state.setLocalTextModelEnabled(true)
        default: await state.retryNextPromptSuggestions()
        }

        #expect(!state.config.nextPromptSuggestionsEnabled)
        #expect(!state.config.sessionSummariesEnabled)
        if action == "retry disable" { #expect(state.nextPromptDisableSavePending) }
        await engine.finishUnloading()
        await removal.value

        // The store's own exclusive lock can still be transiently busy right
        // after the excluded concurrent call tears its work down (the same
        // advisory-lock contention the product's own "retry when it
        // finishes" UI already expects) — retry like a user clicking that
        // button would, same as waitUntilRemoved in NextPromptSettingsTests.
        var attempts = 0
        while state.localTextRemovalFailure != nil {
            attempts += 1
            try #require(attempts < 20)
            await Task.yield()
            await state.removeLocalTextModel()
        }

        #expect(state.localTextModelState == .notInstalled)
        #expect(fixture.transport.requestCount == 0)
        #expect(!state.config.localTextModelEnabled)
        await state.shutdownLocalTextFeatures()
    }

    @Test func removalProgressInvalidatesObservedActionAvailability() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let engine = SuspendedRemovalEngine()
        let state = makeState(fixture, SummarySettingsStore(), engine: engine)
        await state.inspectLocalTextModel()
        state.localTextRuntimeStarted = true
        let invalidations = LockedCounter()
        withObservationTracking {
            _ = state.canRemoveLocalTextModel
        } onChange: {
            invalidations.increment()
        }

        let removal = Task { await state.removeLocalTextModel() }
        await engine.waitUntilUnloading()

        #expect(state.localTextRemovalInProgress)
        #expect(!state.canRemoveLocalTextModel)
        #expect(invalidations.value == 1)
        await engine.finishUnloading()
        await removal.value
        await state.shutdownLocalTextFeatures()
    }

    @Test func startupSkipsInspectionWhenModelPermissionIsOff() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let inspections = LockedCounter()
        let state = makeState(fixture, SummarySettingsStore(), readModelState: {
            inspections.increment()
            return await fixture.store.state
        }, modelEnabled: false)

        await Task.yield()

        #expect(inspections.value == 0)
        #expect(state.localTextModelState == .notInstalled)
        await state.shutdownLocalTextFeatures()
    }

    @Test func openingSettingsInspectsDisallowedModelOnce() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let inspections = LockedCounter()
        let state = makeState(fixture, SummarySettingsStore(), readModelState: {
            inspections.increment()
            return await fixture.store.state
        }, modelEnabled: false)

        await state.inspectLocalTextModelOnSettingsAppearance()
        await state.inspectLocalTextModelOnSettingsAppearance()

        #expect(inspections.value == 1)
        #expect(state.localTextModelState == .ready)
        #expect(state.canRemoveLocalTextModel)
        await state.shutdownLocalTextFeatures()
    }

    @Test func unsupportedRuntimeCanManageFilesWithoutLoadingInference() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let engine = SettingsFeatureEngine()
        let state = makeState(fixture, SummarySettingsStore(configEnabled: true),
                              engine: engine, supported: false)
        #expect(state.localTextObservers.tasks.isEmpty)
        await state.inspectLocalTextModelOnSettingsAppearance()
        #expect(state.localTextModelState == .ready)
        await state.removeLocalTextModel()
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(await engine.unloadCount == 0)
        #expect(await engine.callers.isEmpty)
        await state.shutdownLocalTextFeatures()
    }

    @Test func disablingFallbackTitlesCancelsPendingQwenTitlesImmediately() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let engine = SettingsFeatureEngine()
        let state = makeState(fixture, SummarySettingsStore(), engine: engine)
        let (never, _) = AsyncStream<Void>.makeStream()
        let pendingTitle = Task<LocalTextGenerationResult?, Never> {
            for await _ in never {}
            return nil
        }
        state.qwenTitleRequests.track(pendingTitle)

        state.setACPLocalTitlesEnabled(false)

        #expect(!state.config.harness.acpLocalTitlesEnabled)
        #expect(state.config.issueWorktreeNameSuggestionsEnabled)
        #expect(pendingTitle.isCancelled)
        // A delayed caller-wide engine cancel could hit a title started after
        // consent returns, so revocation only cancels the tracked jobs.
        #expect(await engine.cancelledCallers.isEmpty)
    }

    @Test func titleRequestedWhileEnablingAnInstalledModelWaitsForReadiness() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let state = makeState(fixture, SummarySettingsStore(), engine: SettingsFeatureEngine())
        let enable = Task { await state.enableSessionSummaries() }
        try #require(await awaitCondition { state.config.sessionSummariesEnabled })

        let title = await state.makeQwenTitleFallback().generate(from: "Fix the sign-in race")

        await enable.value
        #expect(title == "Fix sign-in race")
        await state.shutdownLocalTextFeatures()
    }

    @Test func readinessWaitsForEveryOverlappingPreparation() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let state = makeState(fixture, SummarySettingsStore(), engine: SettingsFeatureEngine())
        let slow = ManualGate()
        let fast = ManualGate()
        let slowPreparation = Task { await state.trackLocalTextReadiness { await slow.wait() } }
        try #require(await awaitCondition { slow.isWaiting })
        let fastPreparation = Task { await state.trackLocalTextReadiness { await fast.wait() } }
        try #require(await awaitCondition { fast.isWaiting })
        // The waiter reads the slow gate in the same main-actor job that
        // resumes it, so returning after only the later preparation reads false.
        let waiter = Task {
            await state.waitForLocalTextReadiness()
            return slow.isOpen
        }

        fast.open()
        await fastPreparation.value
        slow.open()
        await slowPreparation.value

        #expect(await waiter.value)
        await state.shutdownLocalTextFeatures()
    }

    @Test func revokingModelPermissionDiscardsAnActiveSummary() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let engine = SettingsFeatureEngine()
        let state = makeState(fixture, SummarySettingsStore(), engine: engine)
        await state.enableSessionSummaries()
        let session = ACPSession(id: "summary", agentId: "test", worktreeId: "w", title: "Summary")
        session.agentState = .ready
        _ = session.recordUserPrompt(text: "Implement search", attachments: [])
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("Search is implemented.")))
        let summary = Task { await state.sessionSummaryCoordinator.summary(for: session) }
        await engine.waitUntilSummaryStarted()
        await state.setLocalTextModelEnabled(false)
        await summary.value
        #expect(state.sessionSummaryCoordinator.phase == .idle)
        #expect(state.config.sessionSummariesEnabled)
        #expect(!state.sessionSummariesRuntimeEnabled)
        #expect(!state.localTextModelAvailable)
        await state.shutdownLocalTextFeatures()
    }

    private func makeState(
        _ fixture: LocalTextModelFixture,
        _ persistence: SummarySettingsStore,
        readModelState: (@Sendable () async -> LocalTextModelState)? = nil,
        engine: (any LocalTextGenerating)? = nil,
        supported: Bool = true, modelEnabled: Bool = true
    ) -> AppState {
        persistence.config.localTextModelEnabled = modelEnabled
        let localEngine = engine ?? LocalTextInferenceEngine(
            acquireLease: { try await fixture.store.acquireVerifiedLease() },
            load: { _ in { _ in .init(text: "", selectedCandidateIndex: 0) } },
            observeMemoryPressure: false
        )
        return AppState(
            store: persistence,
            persistenceErrorHandler: { _, _ in },
            localTextModelStore: fixture.store,
            localTextReadModelState: readModelState,
            localTextInference: localEngine,
            localTextSupported: supported
        )
    }
}

@MainActor
private final class ManualGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isOpen = false
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor SettingsFeatureEngine: LocalTextGenerating {
    private var summaryContinuation: CheckedContinuation<LocalTextGenerationResult, Error>?
    private(set) var callers: [LocalTextCaller] = []
    private(set) var cancelledCallers: [LocalTextCaller] = []
    private(set) var unloadCount = 0
    var hasActiveSummary: Bool { summaryContinuation != nil }

    func generate(
        _ request: LocalTextGenerationRequest,
        caller: LocalTextCaller,
        priority: LocalTextJobPriority
    ) async throws -> LocalTextGenerationResult {
        callers.append(caller)
        if case .sessionSummary = caller {
            return try await withCheckedThrowingContinuation { summaryContinuation = $0 }
        }
        if caller == .sessionTitle { return .init(text: "Fix sign-in race", selectedCandidateIndex: 0) }
        return .init(text: #"{"suggestion":"Show an example."}"#, selectedCandidateIndex: 0)
    }

    func cancel(caller: LocalTextCaller) {
        cancelledCallers.append(caller)
        if case .sessionSummary = caller {
            summaryContinuation?.resume(throwing: LocalTextInferenceFailure.cancelled)
            summaryContinuation = nil
        }
    }

    func cancelAndUnload() {
        unloadCount += 1
        summaryContinuation?.resume(throwing: LocalTextInferenceFailure.cancelled)
        summaryContinuation = nil
    }

    func waitUntilSummaryStarted() async {
        while summaryContinuation == nil { await Task.yield() }
    }

    func completeSummary() {
        summaryContinuation?.resume(returning: .init(
            text: #"{"goal":"Ship search","completed":[],"blockers":[],"next_action":"Run tests"}"#,
            selectedCandidateIndex: 0
        ))
        summaryContinuation = nil
    }

    func resetEvents() {
        callers.removeAll()
        cancelledCallers.removeAll()
        unloadCount = 0
    }
}

private actor SuspendedRemovalEngine: LocalTextGenerating {
    private var continuation: CheckedContinuation<Void, Never>?
    private var unloads = 0

    func generate(
        _ request: LocalTextGenerationRequest,
        caller: LocalTextCaller,
        priority: LocalTextJobPriority
    ) async throws -> LocalTextGenerationResult {
        .init(text: "", selectedCandidateIndex: 0)
    }

    func cancel(caller: LocalTextCaller) {}

    func cancelAndUnload() async {
        unloads += 1
        guard unloads == 1 else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilUnloading() async {
        while continuation == nil { await Task.yield() }
    }

    func finishUnloading() {
        continuation?.resume()
        continuation = nil
    }
}

/// Holds the first `.ready` model-state read, which is the one an installation
/// makes once it finishes, until the test opens it.
actor LocalTextModelStateReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func read(_ store: LocalTextModelStore) async -> LocalTextModelState {
        let value = await store.state
        if value == .ready, !entered {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        return value
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

extension LocalTextModelFixture {
    /// Waits for a point that only a progressing installation reaches. An
    /// installation that settles as `.failed` never gets there, so fail at once
    /// and name the failure instead of waiting out the deadline.
    func waitForInstallation(
        timeout: Duration = .seconds(28),
        isolation: isolated (any Actor)? = #isolation,
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()) {
            let state = await store.state
            if case .failed = state {
                try #require(await condition(), "Installation settled as \(state)", sourceLocation: sourceLocation)
                return
            }
            try #require(ContinuousClock.now < deadline, "Installation still \(state)", sourceLocation: sourceLocation)
            await Task.yield()
        }
    }
}

private actor SummaryCacheEngine: LocalTextGenerating {
    private(set) var summaryRequests = 0

    func generate(
        _ request: LocalTextGenerationRequest,
        caller: LocalTextCaller,
        priority: LocalTextJobPriority
    ) async throws -> LocalTextGenerationResult {
        if case .sessionSummary = caller { summaryRequests += 1 }
        return .init(
            text: #"{"goal":"Ship search","completed":[],"blockers":[],"next_action":"Run tests"}"#,
            selectedCandidateIndex: 0
        )
    }

    func cancel(caller: LocalTextCaller) {}
    func cancelAndUnload() {}
}

private final class SummarySettingsStore: PersistenceStoreProtocol, @unchecked Sendable {
    var config = AppConfig.defaults
    private var saveResults: [Bool]

    init(configEnabled: Bool = false, saveResults: [Bool] = []) {
        config.sessionSummariesEnabled = configEnabled
        self.saveResults = saveResults
    }

    func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? { config as? T }

    func write<T: Encodable>(_ value: T, to _: URL) throws {
        if !saveResults.isEmpty, !saveResults.removeFirst() { throw POSIXError(.EACCES) }
        if let value = value as? AppConfig { config = value }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
