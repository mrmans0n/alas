import AppKit
import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct NextPromptSettingsTests {
    @Test func freshInstallEnablesRuntimeWhenReadyArrivesDuringStateRead() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let gate = SettingsModelStateReadGate()
        let state = makeState(fixture, SettingsStore(), readModelState: { await gate.read(fixture.store) })
        // Deliver ready through inspection at a controlled point instead of the stream.
        state.nextPromptObservers.tasks[0].cancel()
        await state.nextPromptObservers.tasks[0].value
        await state.nextPromptObservers.tasks[2].value
        let enable = Task { await state.enableNextPromptSuggestions() }
        try await waitUntil { await gate.entered }
        #expect(!state.nextPromptRuntimeEnabled)
        let generation = state.nextPromptModelGeneration
        await state.inspectNextPromptModel()
        #expect(state.nextPromptModelState == .ready)
        #expect(state.nextPromptModelGeneration > generation)
        await gate.open()
        await enable.value
        #expect(state.config.nextPromptSuggestionsEnabled)
        #expect(state.nextPromptModelState == .ready)
        #expect(state.nextPromptRuntimeEnabled)
        #expect(fixture.transport.requestCount == fixture.manifest.assets.count)
        await state.shutdownNextPromptSuggestions()
    }

    @Test(arguments: ["cancel", "disable", "remove", "modelChange", "shutdown"])
    func staleCompletedInstallationReadCannotResumeSuggestions(_ interruption: String) async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let gate = SettingsModelStateReadGate()
        let state = makeState(fixture, SettingsStore(), readModelState: { await gate.read(fixture.store) })
        state.nextPromptObservers.tasks[0].cancel()
        await state.nextPromptObservers.tasks[0].value
        await state.nextPromptObservers.tasks[2].value
        let enable = Task { await state.enableNextPromptSuggestions() }
        try await waitUntil { await gate.entered }
        await state.inspectNextPromptModel() // Consume ready before delivering the superseding action.
        switch interruption {
        case "cancel": await state.cancelNextPromptDownload()
        case "disable": await state.disableNextPromptSuggestions()
        case "remove": await state.removeNextPromptModel()
        case "modelChange":
            try await fixture.store.remove()
            await state.inspectNextPromptModel()
        default: await state.shutdownNextPromptSuggestions()
        }
        await gate.open()
        await enable.value
        #expect(!state.nextPromptRuntimeEnabled)
        #expect(state.config.nextPromptSuggestionsEnabled == (interruption != "disable" && interruption != "remove"))
        if interruption == "remove" || interruption == "modelChange" {
            #expect(state.nextPromptModelState == .notInstalled)
        }
        #expect(fixture.transport.requestCount == fixture.manifest.assets.count)
        await state.shutdownNextPromptSuggestions()
    }

    @Test(arguments: ["cancel", "disable", "modelChange", "shutdown"])
    func staleRuntimeStateReadCannotResumeSuggestions(_ interruption: String) async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let runtime = SuspendedSettingsRuntime()
        let state = makeState(fixture, SettingsStore(), inference: runtime)
        let enable = Task { await state.enableNextPromptSuggestions() }
        try await waitUntil { await runtime.isReadingState }
        #expect(!state.nextPromptRuntimeEnabled)
        switch interruption {
        case "cancel": await state.cancelNextPromptDownload()
        case "disable": await state.disableNextPromptSuggestions()
        case "modelChange":
            try await fixture.store.remove()
            await state.inspectNextPromptModel()
        default: await state.shutdownNextPromptSuggestions()
        }
        #expect(!state.nextPromptRuntimeEnabled)
        await runtime.releaseStateRead()
        await enable.value
        #expect(!state.nextPromptRuntimeEnabled)
        #expect(state.config.nextPromptSuggestionsEnabled == (interruption != "disable"))
        #expect(await runtime.retries == 1)
        #expect(fixture.transport.requestCount == 0)
        await state.shutdownNextPromptSuggestions()
    }

    @Test func consentCancellationAndEnabledRelaunchNeverInstall() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let persistence = SettingsStore()
        var state: AppState? = makeState(fixture, persistence)
        await state?.inspectNextPromptModel()
        #expect(!state!.config.nextPromptSuggestionsEnabled)
        #expect(fixture.transport.requestCount == 0)
        state = nil // Dismissing consent never invokes enable.
        persistence.config.nextPromptSuggestionsEnabled = true
        let relaunched = makeState(fixture, persistence)
        await relaunched.inspectNextPromptModel()
        #expect(relaunched.config.nextPromptSuggestionsEnabled)
        #expect(relaunched.nextPromptModelState == .notInstalled)
        #expect(relaunched.nextPromptOffer == nil)
        #expect(fixture.transport.requestCount == 0)
        await relaunched.shutdownNextPromptSuggestions()
    }

    @Test func failedEnableSaveRestoresPreferenceWithoutInstallation() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let persistence = SettingsStore()
        persistence.rejectWrites = true
        let state = makeState(fixture, persistence)
        await state.enableNextPromptSuggestions()
        #expect(!state.config.nextPromptSuggestionsEnabled)
        #expect(fixture.transport.requestCount == 0)
        #expect(state.nextPromptSettingsError != nil)
        await state.shutdownNextPromptSuggestions()
    }

    @Test func cancelledInstallRemainsEnabledUntilExplicitRetry() async throws {
        let fixture = try ModelStoreFixture()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        fixture.transport.mode.withLock { $0 = .waitForCancellation }
        let persistence = SettingsStore()
        let state = makeState(fixture, persistence)
        let enable = Task { await state.enableNextPromptSuggestions() }
        try await waitUntil { fixture.transport.started.withLock { $0 } }
        #expect(persistence.config.nextPromptSuggestionsEnabled)
        await state.cancelNextPromptDownload()
        await enable.value
        #expect(state.config.nextPromptSuggestionsEnabled)
        #expect(state.nextPromptModelState == .notInstalled)
        #expect(fixture.transport.drained.withLock { $0 })
        #expect(fixture.transport.requestCount == 1)
        fixture.transport.mode.withLock { $0 = .valid }
        await state.retryNextPromptSuggestions()
        #expect(state.nextPromptModelState == .ready)
        #expect(state.nextPromptRuntimeEnabled)
        await state.shutdownNextPromptSuggestions()
    }

    @Test func disableRetainsAssetsAndFailedSaveKeepsRuntimeOff() async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let persistence = SettingsStore()
        let state = makeState(fixture, persistence)
        await state.enableNextPromptSuggestions()
        #expect(state.nextPromptRuntimeEnabled)
        persistence.rejectWrites = true
        await state.disableNextPromptSuggestions()
        #expect(!state.nextPromptRuntimeEnabled)
        #expect(!state.config.nextPromptSuggestionsEnabled)
        #expect(state.nextPromptSettingsError != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
        persistence.rejectWrites = false
        await state.enableNextPromptSuggestions()
        #expect(state.nextPromptRuntimeEnabled)
        #expect(fixture.transport.requestCount == 0)
        await state.shutdownNextPromptSuggestions()
    }

    @Test func peerLeaseBlocksRemovalAndExplicitRetryRemovesOnlyOwnedRevision() async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let state = makeState(fixture, SettingsStore())
        await state.enableNextPromptSuggestions()
        let peer = try await fixture.store.acquireVerifiedLease()
        await state.removeNextPromptModel()
        #expect(!state.config.nextPromptSuggestionsEnabled)
        #expect(state.nextPromptRemovalFailure == .inUse)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
        peer.close()
        await state.removeNextPromptModel()
        #expect(state.nextPromptRemovalFailure == nil)
        #expect(state.nextPromptModelState == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".lock").path))
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("unrelated"), encoding: .utf8) == "keep")
        await state.shutdownNextPromptSuggestions()
    }

    @Test func terminationWaitsForEvaluationDrain() async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let gate = SettingsGate()
        let inference = NextPromptInference(acquireLease: { try await fixture.store.acquireVerifiedLease() }, load: { _ in
            return { _ in await gate.wait(); return nil }
        })
        let state = makeState(fixture, SettingsStore(), inference: inference)
        let flush = AlasTerminationCoordinator.shared.flush!
        await state.enableNextPromptSuggestions()
        let request = NextPromptRequest(id: .init(sessionID: "s", incarnation: UUID(), promptID: 1,
            transcriptRevision: 1, draftRevision: 0, composerEpoch: 0, settingsGeneration: 0, modelGeneration: 0),
            turns: [.init(user: "Explain the parser.", assistant: "It reads tokens.")])
        let generation = Task { try? await inference.generate(request) }
        try await waitUntil { await gate.entered }
        var finished = false
        let termination = Task { await flush(); finished = true }
        try await waitUntil { await inference.state == .unloading }
        #expect(!finished)
        await gate.open()
        await termination.value
        _ = await generation.value
        #expect(finished)
        try await fixture.store.remove() // Runtime reader lease was released.
    }

    @Test func explicitRetryResetsSuppressedInference() async throws {
        let fixture = try ModelStoreFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let inference = NextPromptInference(acquireLease: { try await fixture.store.acquireVerifiedLease() }, load: { _ in throw POSIXError(.ENOMEM) })
        let state = makeState(fixture, SettingsStore(), inference: inference)
        await state.enableNextPromptSuggestions()
        let request = NextPromptRequest(id: .init(sessionID: "s", incarnation: UUID(), promptID: 1,
            transcriptRevision: 1, draftRevision: 0, composerEpoch: 0, settingsGeneration: 0, modelGeneration: 0),
            turns: [.init(user: "Explain the parser.", assistant: "It reads tokens.")])
        for _ in 0..<2 { _ = try? await inference.generate(request) }
        #expect(await inference.state == .retryRequired)
        await state.retryNextPromptSuggestions()
        #expect(await inference.state == .ready)
        #expect(fixture.transport.requestCount == 0)
        await state.shutdownNextPromptSuggestions()
    }

    private func makeState(_ fixture: ModelStoreFixture, _ persistence: SettingsStore,
                           inference: (any NextPromptRuntime)? = nil,
                           readModelState: (@Sendable () async -> NextPromptModelState)? = nil) -> AppState {
        AppState(store: persistence, persistenceErrorHandler: { _, _ in },
                 nextPromptModelStore: fixture.store,
                 nextPromptReadModelState: readModelState,
                 nextPromptInference: inference ?? NextPromptInference(acquireLease: { try await fixture.store.acquireVerifiedLease() }, load: { _ in { _ in nil } }),
                 nextPromptSupported: true)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
    }
}

private final class SettingsStore: PersistenceStoreProtocol, @unchecked Sendable {
    var config = AppConfig.defaults
    var rejectWrites = false
    func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? { config as? T }
    func write<T: Encodable>(_ value: T, to _: URL) throws {
        if rejectWrites { throw POSIXError(.EACCES) }
        if let value = value as? AppConfig { config = value }
    }
}

private actor SettingsGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

private actor SuspendedSettingsRuntime: NextPromptRuntime {
    private var stateContinuation: CheckedContinuation<Void, Never>?
    private(set) var isReadingState = false
    private(set) var retries = 0

    var state: NextPromptInferenceState {
        get async {
            isReadingState = true
            await withCheckedContinuation { stateContinuation = $0 }
            return .ready
        }
    }

    func releaseStateRead() { stateContinuation?.resume(); stateContinuation = nil }
    func states() -> AsyncStream<NextPromptInferenceState> { AsyncStream { $0.yield(.ready) } }
    func generate(_ request: NextPromptRequest) async throws -> String? { nil }
    func cancelAndUnload() async {}
    func retryAfterFailure() async { retries += 1 }
}

private actor SettingsModelStateReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func read(_ store: NextPromptModelStore) async -> NextPromptModelState {
        let value = await store.state
        if value == .ready, !entered {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        return value
    }

    func open() { continuation?.resume(); continuation = nil }
}
