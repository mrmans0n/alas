import AppKit
import Combine
import Foundation

/// Owns observer lifetimes, without retaining AppState through long-lived streams.
final class LocalTextObservers {
    var tasks: [Task<Void, Never>] = []
    var notifications: [AnyCancellable] = []
    var managers: [SessionOwnerID: AnyCancellable] = [:]
    var sessions: [UUID: [AnyCancellable]] = [:]
    var pressure: DispatchSourceMemoryPressure?
    var modelStarted = false
    var nextPromptStarted = false

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        notifications.removeAll()
        managers.removeAll()
        sessions.removeAll()
        pressure?.cancel()
        pressure = nil
        modelStarted = false
        nextPromptStarted = false
    }

    deinit { cancel() }
}

extension AppState {
    func startLocalTextObservers() {
        nextPromptRuntimeEnabled = false
        sessionSummariesRuntimeEnabled = false
        guard localTextSupported else { return }
        guard config.nextPromptSuggestionsEnabled || config.sessionSummariesEnabled else { return }

        ensureLocalTextObserversStarted()

        localTextObservers.tasks.append(Task { [weak self] in
            guard let self else { return }
            await self.inspectLocalTextModel()
            guard self.localTextModelState == .ready else { return }
            self.nextPromptRuntimeEnabled = self.config.nextPromptSuggestionsEnabled
            self.sessionSummariesRuntimeEnabled = self.config.sessionSummariesEnabled
            if self.sessionSummariesRuntimeEnabled { self.localTextRuntimeStarted = true }
        })
    }

    func ensureLocalTextObserversStarted() {
        guard localTextSupported else { return }

        if !localTextObservers.modelStarted {
            localTextObservers.modelStarted = true
            let model = localTextModelStore
            localTextObservers.tasks.append(Task { [weak self] in
                for await value in await model.states() {
                    guard !Task.isCancelled else { return }
                    self?.updateLocalTextModelState(value)
                }
            })

            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            pressure.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.invalidateNextPromptContext()
                    self.sessionSummaryCoordinator.teardown()
                    Task { await self.localTextInference.cancelAndUnload() }
                }
            }
            localTextObservers.pressure = pressure
            pressure.resume()
        }

        if config.nextPromptSuggestionsEnabled, !localTextObservers.nextPromptStarted {
            localTextObservers.nextPromptStarted = true
            localTextRuntimeStarted = true
            let runtime = nextPromptInference
            localTextObservers.tasks.append(Task { [weak self] in
                for await value in await runtime.states() {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    if value == .unavailable || value == .retryRequired {
                        self.nextPromptCoordinator.invalidate()
                    }
                    self.nextPromptInferenceState = value
                }
            })
            localTextObservers.notifications.append(nextPromptCoordinator.$offer.sink { [weak self] value in
                self?.nextPromptOffer = value
            })
            for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
                let token = NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.invalidateNextPromptContext() }
                }
                localTextObservers.notifications.append(
                    AnyCancellable { NotificationCenter.default.removeObserver(token) }
                )
            }
        }
    }

    func inspectLocalTextModel() async {
        await localTextModelStore.inspect() // Relaunch never resumes a missing/interrupted install.
        updateLocalTextModelState(await localTextReadModelState())
    }

    func inspectLocalTextModelOnSettingsAppearance() async {
        guard localTextSupported, !localTextSettingsInspected else { return }
        localTextSettingsInspected = true
        await inspectLocalTextModel()
    }

    func updateLocalTextModelState(_ value: LocalTextModelState) {
        guard value != localTextModelState else { return }
        if config.nextPromptSuggestionsEnabled || nextPromptRuntimeEnabled {
            nextPromptCoordinator.invalidate()
        }
        if config.sessionSummariesEnabled || sessionSummariesRuntimeEnabled {
            sessionSummaryCoordinator.teardown()
        }
        localTextModelGeneration &+= 1
        localTextModelState = value
        if value != .ready {
            nextPromptRuntimeEnabled = false
            sessionSummariesRuntimeEnabled = false
        }
    }

    func enableNextPromptSuggestions() async {
        guard localTextSupported, !nextPromptShuttingDown, !nextPromptDisableSavePending,
              !localTextRemovalInProgress else { return }
        localTextRuntimeStarted = true
        let previous = config.nextPromptSuggestionsEnabled
        beginNextPromptSettingsChange()
        let generation = nextPromptSettingsGeneration
        config.nextPromptSuggestionsEnabled = true
        guard saveConfig() else {
            config.nextPromptSuggestionsEnabled = previous
            nextPromptSettingsError = "Could not save next-prompt settings. Suggestions remain off."
            return
        }
        ensureLocalTextObserversStarted()
        await prepareNextPromptSuggestions(generation: generation)
    }

    func retryNextPromptSuggestions() async {
        guard !localTextRemovalInProgress else { return }
        if nextPromptDisableSavePending {
            await disableNextPromptSuggestions()
            return
        }
        guard config.nextPromptSuggestionsEnabled, localTextSupported, !nextPromptShuttingDown else { return }
        beginNextPromptSettingsChange()
        await prepareNextPromptSuggestions(generation: nextPromptSettingsGeneration)
    }

    private func prepareNextPromptSuggestions(generation: UInt64) async {
        await drainNextPromptWork()
        guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown else { return }
        await inspectLocalTextModel()
        guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown else { return }
        if localTextModelState != .ready {
            let install = localTextInstallation ?? Task { await localTextModelStore.install() }
            localTextInstallation = install
            await install.value
            guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown else { return }
            localTextInstallation = nil
            let modelGeneration = localTextModelGeneration
            let modelState = await localTextReadModelState()
            guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown else { return }
            // The installation's own notification may have already delivered this state.
            guard modelGeneration == localTextModelGeneration || modelState == localTextModelState else { return }
            updateLocalTextModelState(modelState)
        }
        guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown,
              config.nextPromptSuggestionsEnabled, localTextModelState == .ready else { return }
        let modelGeneration = localTextModelGeneration
        await nextPromptInference.retryAfterFailure()
        guard generation == nextPromptSettingsGeneration,
              modelGeneration == localTextModelGeneration, !nextPromptShuttingDown else { return }
        let inferenceState = await nextPromptInference.state
        guard generation == nextPromptSettingsGeneration,
              modelGeneration == localTextModelGeneration, !nextPromptShuttingDown else { return }
        nextPromptInferenceState = inferenceState
        nextPromptRuntimeEnabled = inferenceState == .ready
    }

    func cancelLocalTextDownload() async {
        nextPromptSettingsGeneration &+= 1
        sessionSummarySettingsGeneration &+= 1
        nextPromptRuntimeEnabled = false
        sessionSummariesRuntimeEnabled = false
        let installation = localTextInstallation
        localTextInstallation = nil
        installation?.cancel()
        await localTextModelStore.cancelDownload()
        await installation?.value
        updateLocalTextModelState(await localTextReadModelState())
    }

    func retryLocalTextModel() async {
        guard !localTextRemovalInProgress else { return }
        if config.nextPromptSuggestionsEnabled { await retryNextPromptSuggestions() }
        if config.sessionSummariesEnabled { await retrySessionSummarySettings() }
    }

    func disableNextPromptSuggestions() async {
        beginNextPromptSettingsChange()
        config.nextPromptSuggestionsEnabled = false
        nextPromptDisableSavePending = !saveConfig()
        nextPromptSettingsError = nextPromptDisableSavePending
            ? "Could not save disabling. Retry before quitting or suggestions may turn on again after relaunch."
            : nil
        await drainNextPromptWork()
        updateLocalTextModelState(await localTextReadModelState())
    }

    func removeLocalTextModel() async {
        guard canRemoveLocalTextModel else { return }
        localTextRemovalInProgress = true
        defer { localTextRemovalInProgress = false }
        let nextPromptGeneration = nextPromptSettingsGeneration
        let summaryGeneration = sessionSummarySettingsGeneration
        await nextPromptCoordinator.shutdown()
        sessionSummaryCoordinator.teardown()
        if localTextRuntimeStarted { await localTextInference.cancelAndUnload() }
        guard localTextRemovalFlagsAllowRemoval,
              nextPromptGeneration == nextPromptSettingsGeneration,
              summaryGeneration == sessionSummarySettingsGeneration else { return }
        do {
            try await localTextModelStore.remove()
            guard nextPromptGeneration == nextPromptSettingsGeneration,
                  summaryGeneration == sessionSummarySettingsGeneration else { return }
            localTextRemovalFailure = nil
            updateLocalTextModelState(await localTextReadModelState())
        } catch {
            guard nextPromptGeneration == nextPromptSettingsGeneration,
                  summaryGeneration == sessionSummarySettingsGeneration else { return }
            let failure = LocalTextModelFailure.safe(error)
            localTextRemovalFailure = failure == .busy ? .inUse : failure
        }
    }

    var canRemoveLocalTextModel: Bool {
        !localTextRemovalInProgress && localTextRemovalFlagsAllowRemoval
    }

    private var localTextRemovalFlagsAllowRemoval: Bool {
        !config.nextPromptSuggestionsEnabled
            && !config.sessionSummariesEnabled
            && !nextPromptRuntimeEnabled
            && !sessionSummariesRuntimeEnabled
    }

    private func beginNextPromptSettingsChange() {
        nextPromptCoordinator.invalidate()
        nextPromptSettingsGeneration &+= 1
        nextPromptRuntimeEnabled = false
        if !nextPromptDisableSavePending { nextPromptSettingsError = nil }
        localTextRemovalFailure = nil
    }

    private func drainNextPromptWork() async {
        await nextPromptCoordinator.shutdown()
    }

    func shutdownLocalTextFeatures() async {
        nextPromptShuttingDown = true
        beginNextPromptSettingsChange()
        sessionSummariesRuntimeEnabled = false
        sessionSummaryCoordinator.teardown()
        let installation = localTextInstallation
        localTextInstallation = nil
        installation?.cancel()
        await localTextModelStore.cancelDownload()
        await installation?.value
        await nextPromptCoordinator.shutdown()
        if localTextRuntimeStarted {
            await nextPromptInference.cancelAndUnload()
            if nextPromptInferenceOverride != nil { await localTextInference.cancelAndUnload() }
        }
        localTextObservers.cancel()
    }

    func shutdownNextPromptSuggestions() async { await shutdownLocalTextFeatures() }

    func observeNextPromptSessions(_ manager: ACPSessionManager, owner: SessionOwnerID) {
        localTextObservers.managers[owner] = manager.$sessions.sink { [weak self] sessions in
            guard let self else { return }
            for session in sessions.values where self.localTextObservers.sessions[session.incarnation] == nil {
                let incarnation = session.incarnation
                let sessionID = session.id
                self.localTextObservers.sessions[incarnation] = [
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
                        self.localTextObservers.sessions[incarnation] = nil
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
        guard !nextPromptShuttingDown, nextPromptRuntimeEnabled, localTextSupported,
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
        environment.hasVerifiedModel = localTextModelState == .ready
        environment.isRuntimeAvailable = nextPromptInferenceState == .ready ||
            nextPromptInferenceState == .running || nextPromptInferenceState == .failed
        environment.hasForkOrDelegationWork = environment.hasForkOrDelegationWork || nextPromptHasDelegatedWork(parentID: session.id)
        environment.composerEpoch = nextPromptComposerEpoch
        environment.settingsGeneration = nextPromptSettingsGeneration
        environment.modelGeneration = localTextModelGeneration
        return .live(session: session, turn: turn, environment: environment)
    }
}
