import AppKit
import Combine
import Foundation

/// Owns observer lifetimes, without retaining AppState through long-lived streams.
final class NextPromptObservers {
    var tasks: [Task<Void, Never>] = []
    var notifications: [AnyCancellable] = []
    var managers: [SessionOwnerID: AnyCancellable] = [:]
    var sessions: [UUID: [AnyCancellable]] = [:]
    var pressure: DispatchSourceMemoryPressure?

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        notifications.removeAll()
        managers.removeAll()
        sessions.removeAll()
        pressure?.cancel()
        pressure = nil
    }

    deinit { cancel() }
}

extension AppState {
    func startNextPromptObservers() {
        nextPromptRuntimeEnabled = config.nextPromptSuggestionsEnabled && nextPromptSupported
        guard nextPromptSupported else { return }
        let model = nextPromptModelStore, runtime = nextPromptInference
        nextPromptObservers.tasks.append(Task { [weak self] in
            for await value in await model.states() {
                guard !Task.isCancelled else { return }
                self?.updateNextPromptModelState(value)
            }
        })
        nextPromptObservers.tasks.append(Task { [weak self] in
            for await value in await runtime.states() {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if value == .unavailable || value == .retryRequired {
                    self.nextPromptCoordinator.invalidate()
                }
                self.nextPromptInferenceState = value
            }
        })
        nextPromptObservers.tasks.append(Task { [weak self] in await self?.inspectNextPromptModel() })
        nextPromptObservers.notifications.append(nextPromptCoordinator.$offer.sink { [weak self] value in
            self?.nextPromptOffer = value
        })
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateNextPromptContext() }
            }
            nextPromptObservers.notifications.append(AnyCancellable { NotificationCenter.default.removeObserver(token) })
        }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.invalidateNextPromptContext()
                Task { await self.nextPromptInference.cancelAndUnload() }
            }
        }
        nextPromptObservers.pressure = pressure
        pressure.resume()
    }

    func inspectNextPromptModel() async {
        await nextPromptModelStore.inspect() // Relaunch never resumes a missing/interrupted install.
        updateNextPromptModelState(await nextPromptReadModelState())
    }

    private func updateNextPromptModelState(_ value: LocalTextModelState) {
        guard value != nextPromptModelState else { return }
        nextPromptCoordinator.invalidate()
        nextPromptModelGeneration &+= 1
        nextPromptModelState = value
    }

    func enableNextPromptSuggestions() async {
        guard nextPromptSupported, !nextPromptShuttingDown, !nextPromptDisableSavePending else { return }
        let previous = config.nextPromptSuggestionsEnabled
        beginNextPromptSettingsChange()
        let generation = nextPromptSettingsGeneration
        config.nextPromptSuggestionsEnabled = true
        guard saveConfig() else {
            config.nextPromptSuggestionsEnabled = previous
            nextPromptSettingsError = "Could not save next-prompt settings. Suggestions remain off."
            return
        }
        await prepareNextPromptSuggestions(generation: generation)
    }

    func retryNextPromptSuggestions() async {
        if nextPromptDisableSavePending {
            await disableNextPromptSuggestions()
            return
        }
        guard config.nextPromptSuggestionsEnabled, nextPromptSupported, !nextPromptShuttingDown else { return }
        beginNextPromptSettingsChange()
        await prepareNextPromptSuggestions(generation: nextPromptSettingsGeneration)
    }

    private func prepareNextPromptSuggestions(generation: UInt64) async {
        await drainNextPromptWork()
        guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown else { return }
        await inspectNextPromptModel()
        guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown else { return }
        if nextPromptModelState != .ready {
            let install = Task { await nextPromptModelStore.install() }
            nextPromptInstallation = install
            await install.value
            guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown else { return }
            nextPromptInstallation = nil
            let modelGeneration = nextPromptModelGeneration
            let modelState = await nextPromptReadModelState()
            guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown else { return }
            // The installation's own notification may have already delivered this state.
            guard modelGeneration == nextPromptModelGeneration || modelState == nextPromptModelState else { return }
            updateNextPromptModelState(modelState)
        }
        guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown,
              config.nextPromptSuggestionsEnabled, nextPromptModelState == .ready else { return }
        let modelGeneration = nextPromptModelGeneration
        await nextPromptInference.retryAfterFailure()
        guard generation == nextPromptSettingsGeneration,
              modelGeneration == nextPromptModelGeneration, !nextPromptShuttingDown else { return }
        let inferenceState = await nextPromptInference.state
        guard generation == nextPromptSettingsGeneration,
              modelGeneration == nextPromptModelGeneration, !nextPromptShuttingDown else { return }
        nextPromptInferenceState = inferenceState
        nextPromptRuntimeEnabled = inferenceState == .ready
    }

    func cancelNextPromptDownload() async {
        beginNextPromptSettingsChange()
        await drainNextPromptWork()
        updateNextPromptModelState(await nextPromptReadModelState())
    }

    func disableNextPromptSuggestions() async {
        beginNextPromptSettingsChange()
        config.nextPromptSuggestionsEnabled = false
        nextPromptDisableSavePending = !saveConfig()
        nextPromptSettingsError = nextPromptDisableSavePending
            ? "Could not save disabling. Retry before quitting or suggestions may turn on again after relaunch."
            : nil
        await drainNextPromptWork()
        updateNextPromptModelState(await nextPromptReadModelState())
    }

    func removeNextPromptModel() async {
        await disableNextPromptSuggestions()
        let generation = nextPromptSettingsGeneration
        guard !nextPromptRuntimeEnabled, !config.nextPromptSuggestionsEnabled else { return }
        do {
            try await nextPromptModelStore.remove()
            guard generation == nextPromptSettingsGeneration else { return }
            nextPromptRemovalFailure = nil
            updateNextPromptModelState(await nextPromptReadModelState())
        } catch {
            guard generation == nextPromptSettingsGeneration else { return }
            let failure = LocalTextModelFailure.safe(error)
            nextPromptRemovalFailure = failure == .busy ? .inUse : failure
        }
    }

    private func beginNextPromptSettingsChange() {
        nextPromptCoordinator.invalidate()
        nextPromptSettingsGeneration &+= 1
        nextPromptRuntimeEnabled = false
        if !nextPromptDisableSavePending { nextPromptSettingsError = nil }
        nextPromptRemovalFailure = nil
        nextPromptInstallation?.cancel()
    }

    private func drainNextPromptWork() async {
        let installation = nextPromptInstallation
        nextPromptInstallation = nil
        installation?.cancel()
        await nextPromptModelStore.cancelDownload()
        await installation?.value
        await nextPromptCoordinator.shutdown()
        await nextPromptInference.cancelAndUnload()
    }

    func shutdownNextPromptSuggestions() async {
        nextPromptShuttingDown = true
        beginNextPromptSettingsChange()
        await drainNextPromptWork()
        nextPromptObservers.cancel()
    }

    func observeNextPromptSessions(_ manager: ACPSessionManager, owner: SessionOwnerID) {
        nextPromptObservers.managers[owner] = manager.$sessions.sink { [weak self] sessions in
            guard let self else { return }
            for session in sessions.values where self.nextPromptObservers.sessions[session.incarnation] == nil {
                let incarnation = session.incarnation
                let sessionID = session.id
                self.nextPromptObservers.sessions[incarnation] = [
                    session.nextPromptActivity.sink { [weak self] in
                        guard let self,
                              self.nextPromptActiveIncarnation == incarnation ||
                              self.delegatedSessionParents[sessionID].map({ $0 == self.nextPromptSessionID }) == true
                        else { return }
                        self.nextPromptCoordinator.invalidate()
                    },
                    session.nextPromptTeardown.sink { [weak self] in
                        guard let self else { return }
                        self.nextPromptCoordinator.sessionEnded(incarnation: incarnation)
                        self.nextPromptObservers.sessions[incarnation] = nil
                        if self.nextPromptActiveIncarnation == incarnation { self.invalidateNextPromptContext() }
                    }
                ]
            }
        }
    }

    func nextPromptCompleted(_ turn: NextPromptCompletedTurn, owner: SessionOwnerID) {
        guard nextPromptOwner == owner, nextPromptSessionID == turn.sessionID else {
            nextPromptCoordinator.completed(turn) // Consume hidden turns without replacing active context.
            return
        }
        nextPromptCompletedTurn = turn
        if nextPromptSnapshot() != nil { nextPromptActiveIncarnation = turn.incarnation }
        nextPromptCoordinator.completed(turn)
    }

    func nextPromptComposerChanged(_ environment: NextPromptEligibilitySnapshot.Environment,
                                   owner: SessionOwnerID, sessionID: String) {
        guard environment.hasComposerFocus, environment.hasKeyWindow else {
            if nextPromptOwner == owner, nextPromptSessionID == sessionID { invalidateNextPromptContext() }
            return
        }
        if nextPromptOwner != owner || nextPromptSessionID != sessionID {
            invalidateNextPromptContext()
            nextPromptOwner = owner
            nextPromptSessionID = sessionID
        }
        nextPromptActiveIncarnation = acpManager(for: owner)?.sessions[sessionID]?.incarnation
        if nextPromptComposerEnvironment != environment {
            nextPromptCoordinator.invalidate()
            nextPromptComposerEpoch &+= 1
            nextPromptComposerEnvironment = environment
        }
    }

    func invalidateNextPromptContext() {
        nextPromptCoordinator.invalidate()
        nextPromptComposerEpoch &+= 1
        nextPromptCompletedTurn = nil
        nextPromptActiveIncarnation = nil
        nextPromptComposerEnvironment = .init()
    }

    func nextPromptInputBlocked(owner: SessionOwnerID, sessionID: String) -> Bool {
        guard !nextPromptShuttingDown, nextPromptRuntimeEnabled, nextPromptSupported,
              config.nextPromptSuggestionsEnabled, NSApp.isActive,
              let manager = acpManager(for: owner), manager.isWriter(for: sessionID),
              let worktreeID = selectedWorktreeId else { return true }
        let sharedOwner = selectedWorkspaceCheckout.map { SessionOwnerID.workspaceCheckout($0.id, $0.executionLocation) }
        guard case .acpSession(let tab) = centerTabComposition(focusedWorktreeID: worktreeID, sharedSessionOwner: sharedOwner).activeTab,
              tab.sessionId == sessionID,
              owner == (sharedOwner.flatMap { tabs.tabs(for: $0).contains(where: { $0.id == tab.id }) ? $0 : nil } ?? .worktree(worktreeID))
        else { return true }
        return false
    }

    func nextPromptSnapshot() -> NextPromptEligibilitySnapshot? {
        guard let owner = nextPromptOwner, let id = nextPromptSessionID,
              let session = acpManager(for: owner)?.sessions[id], let turn = nextPromptCompletedTurn,
              !nextPromptInputBlocked(owner: owner, sessionID: id),
              let native = NSApp.keyWindow?.firstResponder as? ACPNSTextView else { return nil }
        var environment = native.nextPromptInputState
        environment.isAppActive = NSApp.isActive
        environment.isActiveVisibleWriter = environment.hasKeyWindow
        return nextPromptSnapshot(session: session, turn: turn, environment: environment)
    }

    func nextPromptSnapshot(session: ACPSession, turn: NextPromptCompletedTurn,
                            environment: NextPromptEligibilitySnapshot.Environment) -> NextPromptEligibilitySnapshot? {
        var environment = environment
        environment.isEnabled = nextPromptRuntimeEnabled && config.nextPromptSuggestionsEnabled
        environment.hasVerifiedModel = nextPromptModelState == .ready
        environment.isRuntimeAvailable = nextPromptInferenceState == .ready ||
            nextPromptInferenceState == .running || nextPromptInferenceState == .failed
        environment.hasForkOrDelegationWork = environment.hasForkOrDelegationWork || nextPromptHasDelegatedWork(parentID: session.id)
        environment.composerEpoch = nextPromptComposerEpoch
        environment.settingsGeneration = nextPromptSettingsGeneration
        environment.modelGeneration = nextPromptModelGeneration
        return .live(session: session, turn: turn, environment: environment)
    }
}
