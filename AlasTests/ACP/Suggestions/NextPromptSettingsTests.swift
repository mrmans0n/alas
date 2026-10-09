import AppKit
import Combine
import Foundation
import Synchronization
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct NextPromptSettingsTests {
    @Test(arguments: [
        (NextPromptInferenceState.ready, true), (.running, true), (.unloading, true),
        (.failed, true), (.unavailable, false), (.retryRequired, false)
    ])
    func enabledSuggestionsAcceptWorkWhileTheRuntimeDrains(phase: NextPromptInferenceState, available: Bool) async {
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let state = AppState(store: SettingsStore(), persistenceErrorHandler: { _, _ in }, localTextSupported: true)
        state.config.nextPromptSuggestionsEnabled = true
        state.nextPromptRuntimeEnabled = true
        state.localTextModelState = .ready
        state.nextPromptInferenceState = phase
        let session = ACPSession(id: "s", agentId: "test", worktreeId: "w", title: "Test")
        session.agentState = .ready
        let userID = session.recordUserPrompt(text: "Explain the parser.", attachments: [])
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("It reads tokens.")))
        let turn = NextPromptCompletedTurn(sessionID: session.id, incarnation: session.incarnation,
            promptID: session.allocatePromptID(), userMessageID: userID,
            transcriptRevision: session.transcript.messagesGeneration)
        var environment = NextPromptEligibilitySnapshot.Environment()
        environment.isAppActive = true
        environment.isActiveVisibleWriter = true
        environment.hasComposerFocus = true

        #expect((state.nextPromptSnapshot(session: session, turn: turn, environment: environment) != nil) == available)
        await state.shutdownLocalTextFeatures()
    }

    @Test(arguments: [false, true])
    func startupInspectsInstalledModelOnlyWhenSupported(_ supported: Bool) async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let persistence = SettingsStore()
        persistence.config.nextPromptSuggestionsEnabled = true
        let state = makeState(fixture, persistence, supported: supported)
        // Wait for the one-shot startup inspection if the supported build scheduled it.
        await state.localTextObservers.tasks.last?.value
        #expect(await fixture.store.state == (supported ? .ready : .notInstalled))
        #expect(state.nextPromptRuntimeEnabled == supported)
        #expect(fixture.transport.requestCount == 0)
        await state.shutdownLocalTextFeatures()
    }

    @Test func temporaryFocusAndTabLossPreserveOffer() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let generationCount = Mutex(0)
        let inference = NextPromptInference(
            acquireLease: { try await fixture.store.acquireVerifiedLease() },
            load: { _ in
                { _ in
                    generationCount.withLock { $0 += 1 }
                    return #"{"suggestion":"Show an example."}"#
                }
            }
        )
        let state = makeState(fixture, SettingsStore(), inference: inference)
        await state.enableNextPromptSuggestions()
        let worktree = Worktree(
            id: UUID().uuidString,
            projectId: "p",
            name: "Test",
            branch: "test",
            path: fixture.root,
            status: .clean,
            lastActivity: .now
        )
        let owner = SessionOwnerID.worktree(worktree.id)
        let manager = try #require(state.acpManager(for: worktree))
        defer { manager.shutdownBackgroundTasks() }
        let session = manager.createSession(id: UUID().uuidString, agentId: "test")
        session.agentState = .ready
        state.nextPromptCoordinator = NextPromptCoordinator(engine: inference) { [weak state, weak session] turn in
            guard let state, let session,
                  state.nextPromptActiveIncarnation == turn.incarnation,
                  state.nextPromptComposerEnvironment.hasComposerFocus,
                  state.nextPromptComposerEnvironment.hasKeyWindow else { return nil }
            return state.nextPromptSnapshot(
                session: session,
                turn: turn,
                environment: state.nextPromptComposerEnvironment
            )
        }
        let userID = session.recordUserPrompt(text: "Explain the parser.", attachments: [])
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("It reads tokens.")))
        let turn = NextPromptCompletedTurn(
            sessionID: session.id,
            incarnation: session.incarnation,
            promptID: session.allocatePromptID(),
            userMessageID: userID,
            transcriptRevision: session.transcript.messagesGeneration
        )

        state.nextPromptCompleted(turn, owner: owner)
        #expect(state.nextPromptCoordinator.generationTask == nil)

        var environment = NextPromptEligibilitySnapshot.Environment()
        environment.isAppActive = true
        environment.isActiveVisibleWriter = true
        environment.hasComposerFocus = true
        environment.hasKeyWindow = true
        state.nextPromptComposerChanged(environment, owner: owner, sessionID: session.id)
        await state.nextPromptCoordinator.generationTask?.value
        #expect(state.nextPromptCoordinator.offer == "Show an example.")
        #expect(generationCount.withLock { $0 } == 1)

        environment.hasComposerFocus = false
        state.nextPromptComposerChanged(environment, owner: owner, sessionID: session.id)
        #expect(state.nextPromptCoordinator.offer == nil)
        environment.hasComposerFocus = true
        state.nextPromptComposerChanged(environment, owner: owner, sessionID: session.id)
        #expect(state.nextPromptCoordinator.offer == "Show an example.")
        #expect(generationCount.withLock { $0 } == 1)

        manager.markSessionVisible(id: session.id)
        manager.unmarkSessionVisible(id: session.id)
        #expect(state.nextPromptCoordinator.offer == nil)

        let otherSession = manager.createSession(id: UUID().uuidString, agentId: "test")
        state.nextPromptComposerChanged(environment, owner: owner, sessionID: otherSession.id)
        otherSession.nextPromptActivity.send()

        manager.markSessionVisible(id: session.id)
        state.nextPromptComposerChanged(environment, owner: owner, sessionID: session.id)
        #expect(state.nextPromptCoordinator.offer == "Show an example.")
        #expect(generationCount.withLock { $0 } == 1)

        state.dismissNextPromptOffer(owner: owner, sessionID: session.id)
        state.nextPromptComposerChanged(environment, owner: owner, sessionID: session.id)
        #expect(state.nextPromptCoordinator.offer == nil)
        await state.shutdownLocalTextFeatures()
    }

    @Test(arguments: [("submit in flight", true), ("typing", false), ("typing while blocked", false)])
    func composerStateDuringARunningTurn(_ state: String, offers: Bool) async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let inference = NextPromptInference(acquireLease: { try await fixture.store.acquireVerifiedLease() },
            load: { _ in { _ in #"{"suggestion":"Show an example."}"# } })
        let app = makeState(fixture, SettingsStore(), inference: inference)
        await app.enableNextPromptSuggestions()
        let worktree = Worktree(id: UUID().uuidString, projectId: "p", name: "Test", branch: "test",
                                path: fixture.root, status: .clean, lastActivity: .now)
        let owner = SessionOwnerID.worktree(worktree.id)
        let manager = try #require(app.acpManager(for: worktree))
        defer { manager.shutdownBackgroundTasks() }
        let session = manager.createSession(id: UUID().uuidString, agentId: "test")
        session.agentState = .ready
        app.nextPromptCoordinator = NextPromptCoordinator(engine: inference) { [weak app, weak session] turn in
            guard let app, let session else { return nil }
            return app.nextPromptSnapshot(session: session, turn: turn, environment: app.nextPromptComposerEnvironment)
        }
        var environment = NextPromptEligibilitySnapshot.Environment()
        environment.isAppActive = true
        environment.isActiveVisibleWriter = true
        environment.hasComposerFocus = true
        environment.hasKeyWindow = true
        let userID = session.recordUserPrompt(text: "Explain the parser.", attachments: [])
        let promptID = session.allocatePromptID()

        // A submit's own clear still reports the old caret (a selection) while in flight.
        // Typing consumes the turn even when another blocker (runtime starting) is closed.
        var during = environment
        during.hasSelection = true
        during.hasSubmitInFlight = state == "submit in flight"
        during.isInputBlocked = state != "typing"
        app.nextPromptComposerChanged(during, owner: owner, sessionID: session.id)
        app.nextPromptComposerChanged(environment, owner: owner, sessionID: session.id)
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("It reads tokens.")))
        app.nextPromptCompleted(NextPromptCompletedTurn(sessionID: session.id, incarnation: session.incarnation,
            promptID: promptID, userMessageID: userID, transcriptRevision: session.transcript.messagesGeneration),
            owner: owner)
        await app.nextPromptCoordinator.generationTask?.value

        #expect(app.nextPromptCoordinator.offer == (offers ? "Show an example." : nil))
        await app.shutdownLocalTextFeatures()
    }

    @Test(arguments: ["stream", "delivery", "pending message"])
    func delegatedChildWorkBlocksAndInvalidatesParentSuggestions(_ work: String) async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let inference = NextPromptInference(acquireLease: { try await fixture.store.acquireVerifiedLease() },
            load: { _ in { _ in #"{"suggestion":"Show an example."}"# } })
        let state = makeState(fixture, SettingsStore(), inference: inference)
        await state.enableNextPromptSuggestions()
        let worktree = Worktree(id: UUID().uuidString, projectId: "p", name: "Test", branch: "test",
                                path: fixture.root, status: .clean, lastActivity: .now)
        let owner = SessionOwnerID.worktree(worktree.id)
        let manager = try #require(state.acpManager(for: worktree))
        defer { manager.shutdownBackgroundTasks() }
        let parent = manager.createSession(id: UUID().uuidString, agentId: "test")
        let child = manager.createSession(id: UUID().uuidString, agentId: "test")
        parent.agentState = .ready
        child.agentState = .ready
        state.rememberDelegatedSessionParent(childID: child.id, parentID: parent.id)
        state.nextPromptOwner = owner
        state.nextPromptSessionID = parent.id
        state.nextPromptActiveIncarnation = parent.incarnation
        var facts = NextPromptEligibilitySnapshot.Environment()
        facts.isAppActive = true
        facts.isActiveVisibleWriter = true
        facts.hasComposerFocus = true
        let environment = facts
        state.nextPromptCoordinator = NextPromptCoordinator(engine: inference) { [weak state, weak parent] turn in
            guard let state, let parent else { return nil }
            return state.nextPromptSnapshot(session: parent, turn: turn, environment: environment)
        }

        func setChildWorking(_ working: Bool) {
            if work == "stream" { child.transcript.streamingState = working ? .streaming : .idle }
            else if work == "delivery" { child.nextPromptWorkCount = working ? 1 : 0 }
            else { child.hasPendingDelegatedMessages = working }
        }
        func completeTurn() -> NextPromptCompletedTurn {
            let userID = parent.recordUserPrompt(text: "Explain the parser.", attachments: [])
            parent.transcript.appendMessage(.agent(id: UUID(), StreamingText("It reads tokens.")))
            let turn = NextPromptCompletedTurn(sessionID: parent.id, incarnation: parent.incarnation,
                promptID: parent.allocatePromptID(), userMessageID: userID,
                transcriptRevision: parent.transcript.messagesGeneration)
            state.nextPromptCompleted(turn, owner: owner)
            return turn
        }
        setChildWorking(true)
        let blockedTurn = completeTurn()
        #expect(state.nextPromptCoordinator.generationTask == nil)
        setChildWorking(false)
        state.nextPromptCompleted(blockedTurn, owner: owner)
        #expect(state.nextPromptCoordinator.generationTask == nil)
        #expect(state.nextPromptCoordinator.offer == nil)
        _ = completeTurn()
        let task = try #require(state.nextPromptCoordinator.generationTask)
        await task.value
        #expect(state.nextPromptCoordinator.offer == "Show an example.")
        setChildWorking(true)
        #expect(state.nextPromptCoordinator.offer == nil)
        #expect(state.nextPromptCoordinator.takeOffer() == nil)
        await state.shutdownLocalTextFeatures()
    }

    @Test(arguments: [false, true])
    func normalCompletionRetriesOnceAfterTransientFailure(secondAttemptFails: Bool) async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let loads = Mutex(0)
        let inference = NextPromptInference(acquireLease: { try await fixture.store.acquireVerifiedLease() }, load: { _ in
            let attempt = loads.withLock {
                $0 += 1
                return $0
            }
            if attempt == 1 || secondAttemptFails { throw POSIXError(.ENOMEM) }
            return { _ in #"{"suggestion":"Show an example."}"# }
        })
        let state = makeState(fixture, SettingsStore(), inference: inference)
        await state.enableNextPromptSuggestions()
        let session = ACPSession(id: "s", agentId: "test", worktreeId: "w", title: "Test")
        session.agentState = .ready
        let owner = SessionOwnerID.worktree("w")
        state.nextPromptOwner = owner
        state.nextPromptSessionID = session.id
        var facts = NextPromptEligibilitySnapshot.Environment()
        facts.isAppActive = true
        facts.isActiveVisibleWriter = true
        facts.hasComposerFocus = true
        facts.hasKeyWindow = true
        let environment = facts
        state.nextPromptCoordinator = NextPromptCoordinator(engine: inference) { [weak state, weak session] turn in
            guard let state, let session else { return nil }
            return state.nextPromptSnapshot(session: session, turn: turn, environment: environment)
        }
        let activity = session.nextPromptActivity.sink { [weak state] in state?.nextPromptCoordinator.invalidate() }
        defer { withExtendedLifetime(activity) {} }

        func completeTurn() -> NextPromptCompletedTurn {
            let userID = session.recordUserPrompt(text: "Explain the parser.", attachments: [])
            session.transcript.appendMessage(.agent(id: UUID(), StreamingText("It reads tokens.")))
            let turn = NextPromptCompletedTurn(sessionID: session.id, incarnation: session.incarnation,
                                               promptID: session.allocatePromptID(), userMessageID: userID,
                                               transcriptRevision: session.transcript.messagesGeneration)
            state.nextPromptCompleted(turn, owner: owner)
            return turn
        }

        let first = completeTurn()
        let firstTask = try #require(state.nextPromptCoordinator.generationTask)
        await firstTask.value
        try await waitUntil { state.nextPromptInferenceState == .failed }
        #expect(state.nextPromptCoordinator.offer == nil)
        #expect(loads.withLock { $0 } == 1)
        state.nextPromptCompleted(first, owner: owner)
        #expect(state.nextPromptCoordinator.generationTask == nil)

        _ = completeTurn()
        let secondTask = try #require(state.nextPromptCoordinator.generationTask)
        await secondTask.value
        if secondAttemptFails {
            try await waitUntil { state.nextPromptInferenceState == .retryRequired }
            _ = completeTurn()
            #expect(state.nextPromptCoordinator.generationTask == nil)
            #expect(state.nextPromptCoordinator.offer == nil)
        } else {
            try await waitUntil { state.nextPromptCoordinator.offer != nil }
            #expect(state.nextPromptCoordinator.takeOffer() == "Show an example.")
        }
        #expect(loads.withLock { $0 } == 2)
        await state.shutdownLocalTextFeatures()
    }

    @Test func freshDownloadEnablesRequestedFeaturesAfterVerification() async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let persistence = SettingsStore()
        persistence.config.nextPromptSuggestionsEnabled = true
        let gate = LocalTextModelStateReadGate()
        let state = makeState(fixture, persistence,
            readModelState: { await gate.read(fixture.store) }, modelEnabled: false)
        let download = Task { await state.downloadLocalTextModel() }
        try await fixture.waitForInstallation { await gate.entered }
        #expect(!state.nextPromptRuntimeEnabled)
        await state.inspectLocalTextModel()
        await gate.open()
        await download.value
        #expect(state.nextPromptRuntimeEnabled)
        #expect(fixture.transport.requestCount == fixture.manifest.assets.count)
        await state.shutdownLocalTextFeatures()
    }

    @Test(arguments: ["disable", "remove", "modelChange", "shutdown"])
    func staleDownloadReadCannotResumeSuggestions(_ interruption: String) async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let persistence = SettingsStore()
        persistence.config.nextPromptSuggestionsEnabled = true
        let gate = LocalTextModelStateReadGate()
        let state = makeState(fixture, persistence,
            readModelState: { await gate.read(fixture.store) }, modelEnabled: false)
        let download = Task { await state.downloadLocalTextModel() }
        try await fixture.waitForInstallation { await gate.entered }
        await state.inspectLocalTextModel()
        switch interruption {
        case "disable": await state.disableNextPromptSuggestions()
        case "remove": await state.removeLocalTextModel()
        case "modelChange":
            try await waitUntilRemoved(fixture)
            await state.inspectLocalTextModel()
        default: await state.shutdownLocalTextFeatures()
        }
        await gate.open()
        await download.value
        #expect(!state.nextPromptRuntimeEnabled)
        #expect(state.config.nextPromptSuggestionsEnabled == (interruption != "disable"))
        if interruption == "remove" || interruption == "modelChange" {
            #expect(state.localTextModelState == .notInstalled)
        }
        await state.shutdownLocalTextFeatures()
    }

    @Test(arguments: ["disable", "modelChange", "shutdown"])
    func staleRuntimeStateReadCannotResumeSuggestions(_ interruption: String) async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let runtime = SuspendedSettingsRuntime()
        let state = makeState(fixture, SettingsStore(), inference: runtime)
        let enable = Task { await state.enableNextPromptSuggestions() }
        try await waitUntil { await runtime.isReadingState }
        #expect(!state.nextPromptRuntimeEnabled)
        switch interruption {
        case "disable": await state.disableNextPromptSuggestions()
        case "modelChange":
            // The store's own exclusive-lock guard is advisory and, like the product's
            // own "retry when it finishes" UI for .busy, expected to be momentarily
            // contended right after a concurrent inspection — retry rather than fail.
            try await waitUntilRemoved(fixture)
            await state.inspectLocalTextModel()
        default: await state.shutdownLocalTextFeatures()
        }
        #expect(!state.nextPromptRuntimeEnabled)
        await runtime.releaseStateRead()
        await enable.value
        #expect(!state.nextPromptRuntimeEnabled)
        #expect(state.config.nextPromptSuggestionsEnabled == (interruption != "disable"))
        #expect(await runtime.retries == 1)
        #expect(fixture.transport.requestCount == 0)
        await state.shutdownLocalTextFeatures()
    }

    @Test func consentCancellationAndEnabledRelaunchNeverInstall() async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let persistence = SettingsStore()
        var state: AppState? = makeState(fixture, persistence)
        await state?.inspectLocalTextModel()
        #expect(!state!.config.nextPromptSuggestionsEnabled)
        #expect(fixture.transport.requestCount == 0)
        state = nil // Dismissing consent never invokes enable.
        persistence.config.nextPromptSuggestionsEnabled = true
        let relaunched = makeState(fixture, persistence)
        await relaunched.inspectLocalTextModel()
        #expect(relaunched.config.nextPromptSuggestionsEnabled)
        #expect(relaunched.localTextModelState == .notInstalled)
        #expect(relaunched.nextPromptOffer == nil)
        #expect(fixture.transport.requestCount == 0)
        await relaunched.shutdownLocalTextFeatures()
    }

    @Test func failedEnableSaveRestoresPreferenceWithoutInstallation() async throws {
        let fixture = try LocalTextModelFixture()
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
        await state.shutdownLocalTextFeatures()
    }

    @Test func cancelledDownloadRequiresAnExplicitDownloadRetry() async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        fixture.transport.mode.withLock { $0 = .waitForCancellation }
        let persistence = SettingsStore()
        persistence.config.nextPromptSuggestionsEnabled = true
        let state = makeState(fixture, persistence, modelEnabled: false)
        let download = Task { await state.downloadLocalTextModel() }
        try await fixture.waitForInstallation { fixture.transport.started.withLock { $0 } }
        await state.cancelLocalTextDownload()
        await download.value
        #expect(state.config.localTextModelEnabled)
        #expect(state.localTextModelState == .notInstalled)
        #expect(fixture.transport.drained.withLock { $0 })
        await state.retryNextPromptSuggestions()
        #expect(fixture.transport.requestCount == 1)
        fixture.transport.mode.withLock { $0 = .valid }
        await state.retryLocalTextModelDownload()
        #expect(state.localTextModelState == .ready)
        #expect(state.nextPromptRuntimeEnabled)
        await state.shutdownLocalTextFeatures()
    }

    @Test func failedDisableRemainsRetryableAndStaysOffAfterRelaunch() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
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
        #expect(persistence.config.nextPromptSuggestionsEnabled)
        #expect(state.nextPromptDisableSavePending)
        #expect(state.nextPromptSettingsError != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
        await state.retryNextPromptSuggestions()
        #expect(state.nextPromptDisableSavePending)
        #expect(!state.nextPromptRuntimeEnabled)
        persistence.rejectWrites = false
        await state.enableNextPromptSuggestions()
        #expect(!state.nextPromptRuntimeEnabled)
        await state.retryNextPromptSuggestions()
        #expect(!persistence.config.nextPromptSuggestionsEnabled)
        #expect(!state.nextPromptDisableSavePending)
        #expect(!state.nextPromptRuntimeEnabled)
        #expect(state.nextPromptSettingsError == nil)
        #expect(fixture.transport.requestCount == 0)
        await state.shutdownLocalTextFeatures()
        let relaunched = makeState(fixture, persistence)
        await relaunched.inspectLocalTextModel()
        #expect(!relaunched.config.nextPromptSuggestionsEnabled)
        #expect(!relaunched.nextPromptRuntimeEnabled)
        #expect(relaunched.localTextModelState == .ready)
        await relaunched.enableNextPromptSuggestions()
        #expect(relaunched.nextPromptRuntimeEnabled)
        #expect(fixture.transport.requestCount == 0)
        await relaunched.shutdownLocalTextFeatures()
    }

    @Test func peerLeaseBlocksRemovalAndExplicitRetryRemovesOnlyOwnedRevision() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let persistence = SettingsStore()
        persistence.config.nextPromptSuggestionsEnabled = true
        persistence.config.sessionSummariesEnabled = true
        let state = makeState(fixture, persistence)
        await state.localTextObservers.tasks.last?.value
        let peer = try await fixture.store.acquireVerifiedLease()
        await state.removeLocalTextModel()
        #expect(state.config.nextPromptSuggestionsEnabled)
        #expect(state.config.sessionSummariesEnabled)
        #expect(state.localTextRemovalFailure == .inUse)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
        peer.close()
        await state.removeLocalTextModel()
        #expect(state.localTextRemovalFailure == nil)
        #expect(state.localTextModelState == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".lock").path))
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("unrelated"), encoding: .utf8) == "keep")
        await state.shutdownLocalTextFeatures()
    }

    @Test func terminationWaitsForEvaluationDrain() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let gate = SettingsGate()
        let inference = NextPromptInference(acquireLease: { try await fixture.store.acquireVerifiedLease() }, load: { _ in
            return { _ in
                await gate.wait()
                return nil
            }
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
        let termination = Task {
            await flush()
            finished = true
        }
        try await waitUntil { await inference.state == .unloading }
        #expect(!finished)
        await gate.open()
        await termination.value
        _ = await generation.value
        #expect(finished)
        try await fixture.store.remove() // Runtime reader lease was released.
    }

    @Test func featureEnableAndRuntimeRetryNeverDownloadMissingAssets() async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let state = makeState(fixture, SettingsStore())
        await state.localTextObservers.tasks.last?.value
        await state.enableNextPromptSuggestions()
        await state.enableSessionSummaries()
        await state.retryNextPromptSuggestions()
        await state.retrySessionSummarySettings()
        await state.retryLocalTextModelSettings()
        #expect(fixture.transport.requestCount == 0)
        #expect(state.localTextModelState == .notInstalled)
        #expect(!state.nextPromptRuntimeEnabled)
        #expect(!state.sessionSummariesRuntimeEnabled)
        await state.shutdownLocalTextFeatures()
    }

    @Test func rejectedDownloadConsentDoesNotFetchFiles() async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let persistence = SettingsStore()
        let state = makeState(fixture, persistence, modelEnabled: false)
        persistence.rejectWrites = true
        await state.downloadLocalTextModel()
        await state.retryNextPromptSuggestions()
        #expect(fixture.transport.requestCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(!persistence.config.localTextModelEnabled)
        #expect(state.localTextModelSettingsError != nil)
        await state.shutdownLocalTextFeatures()
    }

    @Test func failedRevocationCannotBeUndoneByLateReadiness() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let persistence = SettingsStore()
        persistence.config.nextPromptSuggestionsEnabled = true
        let gate = LocalTextModelStateReadGate()
        let state = makeState(fixture, persistence,
                              readModelState: { await gate.read(fixture.store) })
        try await waitUntil { await gate.entered }
        let oldReadiness = state.localTextObservers.tasks.last
        persistence.rejectWrites = true
        await state.setLocalTextModelEnabled(false)
        await gate.open()
        await oldReadiness?.value
        #expect(persistence.config.localTextModelEnabled)
        #expect(state.localTextModelDisableSavePending)
        #expect(!state.localTextModelAvailable)
        #expect(!state.nextPromptRuntimeEnabled)
        #expect(!state.sessionSummariesRuntimeEnabled)
        persistence.rejectWrites = false
        await state.retryLocalTextModelSettings()
        #expect(!persistence.config.localTextModelEnabled)
        #expect(!state.localTextModelDisableSavePending)
        await state.shutdownLocalTextFeatures()
    }

    @Test func removalWaitsForPersistedPermissionRevocation() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let persistence = SettingsStore()
        let state = makeState(fixture, persistence)
        await state.localTextObservers.tasks.last?.value
        persistence.rejectWrites = true
        await state.removeLocalTextModel()
        #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(state.localTextModelDisableSavePending)
        #expect(!state.localTextModelAvailable)
        persistence.rejectWrites = false
        await state.removeLocalTextModel()
        #expect(state.localTextModelState == .notInstalled)
        #expect(!persistence.config.localTextModelEnabled)
        await state.shutdownLocalTextFeatures()
    }

    @Test(arguments: ["titles", "names", "briefs"])
    func rejectedHelperDisableRemainsOffUntilRetryPersists(_ helper: String) async throws {
        let fixture = try LocalTextModelFixture()
        defer { fixture.removeTemporaryRoot() }
        let previous = AlasTerminationCoordinator.shared.flush
        defer { AlasTerminationCoordinator.shared.flush = previous }
        let persistence = SettingsStore()
        let state = makeState(fixture, persistence, modelEnabled: false)
        func enabled(in config: AppConfig) -> Bool {
            switch helper {
            case "titles": return config.harness.acpLocalTitlesEnabled
            case "names": return config.issueWorktreeNameSuggestionsEnabled
            default: return config.runFailureBriefsEnabled
            }
        }
        persistence.rejectWrites = true
        switch helper {
        case "titles": state.setACPLocalTitlesEnabled(false)
        case "names": state.setIssueWorktreeNameSuggestionsEnabled(false)
        default: state.setRunFailureBriefsEnabled(false)
        }
        #expect(!enabled(in: state.config))
        #expect(enabled(in: persistence.config))
        #expect(state.onDeviceAIHelperSettingsError != nil)
        persistence.rejectWrites = false
        state.retryOnDeviceAIHelperSettings()
        #expect(!enabled(in: persistence.config))
        #expect(state.onDeviceAIHelperSettingsError == nil)
        await state.shutdownLocalTextFeatures()
    }

    @Test func explicitRetryResetsSuppressedInference() async throws {
        let fixture = try LocalTextModelFixture.verifiedInstall()
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
        await state.shutdownLocalTextFeatures()
    }

    private func makeState(_ fixture: LocalTextModelFixture, _ persistence: SettingsStore,
                           inference: (any NextPromptRuntime)? = nil,
                           readModelState: (@Sendable () async -> LocalTextModelState)? = nil,
                           supported: Bool = true, modelEnabled: Bool = true) -> AppState {
        persistence.config.localTextModelEnabled = modelEnabled
        return AppState(store: persistence, persistenceErrorHandler: { _, _ in },
                 localTextModelStore: fixture.store,
                 localTextReadModelState: readModelState,
                 nextPromptInference: inference ?? NextPromptInference(acquireLease: { try await fixture.store.acquireVerifiedLease() }, load: { _ in { _ in nil } }),
                 localTextSupported: supported)
    }

    /// Removal races benignly with a concurrent inspection's advisory lock; retry
    /// like the product's own "retry when it finishes" .busy handling does.
    private func waitUntilRemoved(_ fixture: LocalTextModelFixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while true {
            do {
                try await fixture.store.remove()
                return
            } catch LocalTextModelFailure.busy {
                try #require(ContinuousClock.now < deadline)
                await Task.yield()
            }
        }
    }

    private func waitUntil(timeout: Duration = .seconds(28), _ condition: () async -> Bool) async throws {
        // 5s was too tight on loaded CI runners: the tasks under test are real actor
        // hops (and, for callers awaiting a freshly-spawned Task's first
        // scheduling turn, `Task.detached` work) competing with ~1300 other
        // tests' work on the same cooperative pool. 20s wasn't always enough
        // either — three different tests in this file have now each missed
        // it at least once, always by a small margin, implying the spawned
        // task's own first scheduling turn (not this loop) is what's slow.
        // 28s keeps the one test that calls this twice at 56s total, still
        // under the harness's 60s per-test execution allowance; callers
        // waiting on nothing else (see cancelledInstallRemainsEnabledUntilExplicitRetry)
        // can ask for more headroom still.
        let deadline = ContinuousClock.now.advanced(by: timeout)
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
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        continuation?.resume()
        continuation = nil
    }
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

    func releaseStateRead() {
        stateContinuation?.resume()
        stateContinuation = nil
    }
    func states() -> AsyncStream<NextPromptInferenceState> { AsyncStream { $0.yield(.ready) } }
    func generate(_ request: NextPromptRequest) async throws -> String? { nil }
    func cancelAndUnload() async {}
    func retryAfterFailure() async { retries += 1 }
}
