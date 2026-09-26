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
        #expect(LocalTextModelSettings.sessionSummaryReadyDetail(
            requested: state.config.sessionSummariesEnabled,
            runtimeEnabled: state.sessionSummariesRuntimeEnabled,
            disableSavePending: state.sessionSummaryDisableSavePending
        ) == "Model installed. Session summaries are off for this session.")

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

    @Test(arguments: [
        LocalTextModelState.notInstalled,
        .failed(.filesystem)
    ])
    func staleCompletedSummaryInstallationReadCannotReplaceNewerState(
        _ newerState: LocalTextModelState
    ) async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        let gate = SummaryModelStateReadGate()
        let state = makeState(
            fixture,
            SummarySettingsStore(),
            readModelState: { await gate.read(fixture.store) }
        )
        let enable = Task { await state.enableSessionSummaries() }
        await gate.waitUntilEntered()
        let modelObserver = state.localTextObservers.tasks.first
        modelObserver?.cancel()
        await modelObserver?.value
        state.updateLocalTextModelState(newerState)

        await gate.open()
        await enable.value

        #expect(state.localTextModelState == newerState)
        #expect(!state.sessionSummariesRuntimeEnabled)
        await state.shutdownLocalTextFeatures()
    }

    @Test func enablingEitherCapabilityUsesOneInstallationAndCapabilitySpecificConsent() async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        let state = makeState(fixture, SummarySettingsStore())

        #expect(LocalTextModelSettings.nextPromptConsent != LocalTextModelSettings.sessionSummaryConsent)
        #expect(LocalTextModelSettings.sessionSummaryConsent.contains("2.3 GB"))
        #expect(LocalTextModelSettings.sessionSummaryConsent.contains("transcript"))
        #expect(LocalTextModelSettings.sessionSummaryConsent.contains("multi-gigabyte"))
        #expect(LocalTextModelSettings.sessionSummaryConsent.contains("remain"))

        await state.enableSessionSummaries()
        let installedRequests = fixture.transport.requestCount
        await state.enableNextPromptSuggestions()

        #expect(installedRequests == fixture.manifest.assets.count)
        #expect(fixture.transport.requestCount == installedRequests)
        #expect(state.sessionSummariesRuntimeEnabled)
        #expect(state.nextPromptRuntimeEnabled)
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

    @Test func disablingLastCapabilityCancelsSummaryInstallation() async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        fixture.transport.mode.withLock { $0 = .waitForCancellation }
        let state = makeState(fixture, SummarySettingsStore())
        let enable = Task { await state.enableSessionSummaries() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !fixture.transport.started.withLock({ $0 }), ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(fixture.transport.started.withLock { $0 })

        await state.disableSessionSummaries()

        #expect(fixture.transport.drained.withLock { $0 })
        if !fixture.transport.drained.withLock({ $0 }) { await state.cancelLocalTextDownload() }
        await enable.value
        #expect(state.localTextInstallation == nil)
        #expect(!state.config.sessionSummariesEnabled)
        #expect(state.localTextModelState == .notInstalled)
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

    @Test func removalRequiresBothCapabilitiesDisabled() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let state = makeState(fixture, SummarySettingsStore())
        await state.inspectLocalTextModel()

        for flags in [(true, false, false, false), (false, true, false, false),
                      (false, false, true, false), (false, false, false, true)] {
            state.config.nextPromptSuggestionsEnabled = flags.0
            state.config.sessionSummariesEnabled = flags.1
            state.nextPromptRuntimeEnabled = flags.2
            state.sessionSummariesRuntimeEnabled = flags.3
            #expect(!state.canRemoveLocalTextModel)
        }

        state.config.nextPromptSuggestionsEnabled = false
        state.config.sessionSummariesEnabled = false
        state.nextPromptRuntimeEnabled = false
        state.sessionSummariesRuntimeEnabled = false
        #expect(state.canRemoveLocalTextModel)
        await state.removeLocalTextModel()
        #expect(state.localTextModelState == .notInstalled)
        await state.shutdownLocalTextFeatures()
    }

    @Test(arguments: ["enable next", "enable summary", "retry disable"])
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

    @Test func startupSkipsInspectionWhenBothCapabilitiesAreDisabled() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let inspections = LockedCounter()
        let state = makeState(fixture, SummarySettingsStore(), readModelState: {
            inspections.increment()
            return await fixture.store.state
        })

        await Task.yield()

        #expect(inspections.value == 0)
        #expect(state.localTextModelState == .notInstalled)
        await state.shutdownLocalTextFeatures()
    }

    @Test func openingSettingsInspectsOnceWhenBothCapabilitiesAreDisabled() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let inspections = LockedCounter()
        let state = makeState(fixture, SummarySettingsStore(), readModelState: {
            inspections.increment()
            return await fixture.store.state
        })

        await state.inspectLocalTextModelOnSettingsAppearance()
        await state.inspectLocalTextModelOnSettingsAppearance()

        #expect(inspections.value == 1)
        #expect(state.localTextModelState == .ready)
        #expect(state.canRemoveLocalTextModel)
        await state.shutdownLocalTextFeatures()
    }

    @Test func unsupportedBuildStartsNoObserversAndPerformsNoInspection() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let inspections = LockedCounter()
        let store = SummarySettingsStore(configEnabled: true)
        let state = makeState(fixture, store, readModelState: {
            inspections.increment()
            return await fixture.store.state
        }, supported: false)

        await Task.yield()
        await state.inspectLocalTextModelOnSettingsAppearance()

        #expect(inspections.value == 0)
        #expect(state.localTextObservers.tasks.isEmpty)
        #expect(state.localTextObservers.notifications.isEmpty)
        #expect(state.localTextObservers.pressure == nil)
        #expect(!state.sessionSummariesRuntimeEnabled)
        await state.shutdownLocalTextFeatures()
    }

    private func makeState(
        _ fixture: LocalTextModelFixture,
        _ persistence: SummarySettingsStore,
        readModelState: (@Sendable () async -> LocalTextModelState)? = nil,
        engine: (any LocalTextGenerating)? = nil,
        supported: Bool = true
    ) -> AppState {
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

private actor SummaryModelStateReadGate {
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

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func open() {
        continuation?.resume()
        continuation = nil
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
