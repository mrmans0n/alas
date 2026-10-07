import AppKit
import Combine
import Foundation
import os

extension AppState {
    func ensureNextPromptObserversStarted() {
        if config.nextPromptSuggestionsEnabled, !localTextObservers.nextPromptStarted {
            localTextObservers.nextPromptStarted = true
            localTextRuntimeStarted = true
            let runtime = nextPromptInference
            localTextObservers.tasks.append(Task { [weak self] in
                for await value in await runtime.states() {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    if value == .unavailable || value == .retryRequired {
                        self.nextPromptCoordinator.invalidateAll()
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
                    MainActor.assumeIsolated { self?.suspendNextPromptPresentation() }
                }
                localTextObservers.notifications.append(
                    AnyCancellable { NotificationCenter.default.removeObserver(token) }
                )
            }
            for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
                let token = NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconsiderNextPromptPresentation() }
                }
                localTextObservers.notifications.append(
                    AnyCancellable { NotificationCenter.default.removeObserver(token) }
                )
            }
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
        await trackLocalTextReadiness { await self.prepareNextPromptSuggestions(generation: generation) }
    }

    func retryNextPromptSuggestions() async {
        guard !localTextRemovalInProgress else { return }
        if nextPromptDisableSavePending {
            await disableNextPromptSuggestions()
            return
        }
        guard config.nextPromptSuggestionsEnabled, localTextSupported, !nextPromptShuttingDown else { return }
        beginNextPromptSettingsChange()
        let generation = nextPromptSettingsGeneration
        await trackLocalTextReadiness { await self.prepareNextPromptSuggestions(generation: generation) }
    }

    private func prepareNextPromptSuggestions(generation: UInt64) async {
        await drainNextPromptWork()
        guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown else { return }
        await inspectLocalTextModel()
        guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown else { return }
        guard generation == nextPromptSettingsGeneration, !nextPromptShuttingDown,
              config.nextPromptSuggestionsEnabled, localTextModelAvailable,
              !nextPromptDisableSavePending else { return }
        let modelGeneration = localTextModelGeneration
        await nextPromptInference.retryAfterFailure()
        guard generation == nextPromptSettingsGeneration, localTextModelAvailable,
              modelGeneration == localTextModelGeneration, !nextPromptShuttingDown else { return }
        let inferenceState = await nextPromptInference.state
        guard generation == nextPromptSettingsGeneration, localTextModelAvailable,
              modelGeneration == localTextModelGeneration, !nextPromptShuttingDown else { return }
        nextPromptInferenceState = inferenceState
        nextPromptRuntimeEnabled = inferenceState == .ready
    }

    func disableNextPromptSuggestions() async {
        beginNextPromptSettingsChange()
        config.nextPromptSuggestionsEnabled = false
        nextPromptDisableSavePending = !saveConfig()
        nextPromptSettingsError = nextPromptDisableSavePending
            ? "Could not save disabling. Retry before quitting or suggestions may turn on again after relaunch."
            : nil
        await drainNextPromptWork()
    }

    func beginNextPromptSettingsChange() {
        if localTextRuntimeStarted { nextPromptCoordinator.invalidateAll() }
        nextPromptSettingsGeneration &+= 1
        nextPromptRuntimeEnabled = false
        if !nextPromptDisableSavePending { nextPromptSettingsError = nil }
        localTextRemovalFailure = nil
    }

    private func drainNextPromptWork() async {
        await nextPromptCoordinator.shutdown()
    }

    func observeNextPromptSessions(_ manager: ACPSessionManager, owner: SessionOwnerID) {
        localTextObservers.managers[owner] = manager.$sessions.sink { [weak self] sessions in
            guard let self else { return }
            for session in sessions.values where self.localTextObservers.sessions[session.incarnation] == nil {
                let incarnation = session.incarnation
                let sessionID = session.id
                self.localTextObservers.sessions[incarnation] = [
                    session.nextPromptActivity.sink { [weak self] in
                        guard let self else { return }
                        self.nextPromptCoordinator.invalidate(incarnation: incarnation, reason: "session activity")
                        if let parentID = self.delegatedSessionParents[sessionID] {
                            self.nextPromptCoordinator.invalidate(sessionID: parentID)
                        }
                        if self.nextPromptActiveIncarnation == incarnation {
                            self.nextPromptComposerEpochs[incarnation, default: 0] &+= 1
                        }
                    },
                    session.nextPromptVisibilityChanged.sink { [weak self] isVisible in
                        guard let self, self.nextPromptActiveIncarnation == incarnation else { return }
                        if isVisible {
                            self.nextPromptCoordinator.reconsider(incarnation: incarnation)
                        } else {
                            self.nextPromptCoordinator.suspend(incarnation: incarnation)
                        }
                    },
                    session.nextPromptTeardown.sink { [weak self] in
                        guard let self else { return }
                        self.nextPromptCoordinator.sessionEnded(incarnation: incarnation)
                        self.nextPromptComposerEpochs[incarnation] = nil
                        self.localTextObservers.sessions[incarnation] = nil
                        if self.nextPromptActiveIncarnation == incarnation {
                            self.clearNextPromptPresentationContext()
                        }
                    }
                ]
            }
        }
    }

    func nextPromptCompleted(_ turn: NextPromptCompletedTurn, owner: SessionOwnerID) {
        nextPromptCoordinator.completed(turn)
    }

    func nextPromptComposerChanged(_ environment: NextPromptEligibilitySnapshot.Environment,
                                   owner: SessionOwnerID, sessionID: String) {
        guard environment.hasComposerFocus, environment.hasKeyWindow else {
            if nextPromptOwner == owner, nextPromptSessionID == sessionID {
                nextPromptComposerEnvironment = environment
                suspendNextPromptPresentation()
            }
            return
        }
        if nextPromptOwner != owner || nextPromptSessionID != sessionID {
            suspendNextPromptPresentation()
            nextPromptOwner = owner
            nextPromptSessionID = sessionID
        }
        guard let session = acpManager(for: owner)?.sessions[sessionID] else {
            clearNextPromptPresentationContext()
            return
        }
        let incarnation = session.incarnation
        nextPromptActiveIncarnation = incarnation
        nextPromptComposerEnvironment = environment
        if environment.hasPendingInput || environment.hasSelection || environment.hasMarkedText ||
            environment.isDictating || environment.isPickerPresented {
            nextPromptCoordinator.invalidate(incarnation: incarnation, throughPromptID: session.nextPromptID - 1,
                                             reason: "composer input")
            nextPromptComposerEpochs[incarnation, default: 0] &+= 1
            return
        }
        nextPromptCoordinator.reconsider(incarnation: incarnation)
    }

    func dismissNextPromptOffer(owner: SessionOwnerID, sessionID: String) {
        guard nextPromptOwner == owner, nextPromptSessionID == sessionID,
              let session = acpManager(for: owner)?.sessions[sessionID],
              session.incarnation == nextPromptActiveIncarnation else { return }
        nextPromptCoordinator.invalidate(
            incarnation: session.incarnation,
            throughPromptID: session.nextPromptID - 1,
            reason: "dismissed"
        )
        nextPromptComposerEpochs[session.incarnation, default: 0] &+= 1
    }

    func suspendNextPromptPresentation() {
        guard let incarnation = nextPromptActiveIncarnation else { return }
        nextPromptCoordinator.suspend(incarnation: incarnation)
    }

    func reconsiderNextPromptPresentation() {
        guard let incarnation = nextPromptActiveIncarnation else { return }
        nextPromptCoordinator.reconsider(incarnation: incarnation)
    }

    func invalidateAllNextPromptContexts() {
        nextPromptCoordinator.invalidateAll()
        clearNextPromptPresentationContext()
    }

    private func clearNextPromptPresentationContext() {
        nextPromptOwner = nil
        nextPromptSessionID = nil
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

    func nextPromptSnapshot(for turn: NextPromptCompletedTurn) -> NextPromptEligibilitySnapshot? {
        guard let owner = nextPromptOwner, let id = nextPromptSessionID,
              let session = acpManager(for: owner)?.sessions[id],
              session.incarnation == turn.incarnation else {
            nextPromptLogger.debug("prompt \(turn.promptID) ineligible: composer shows another session")
            return nil
        }
        guard !nextPromptInputBlocked(owner: owner, sessionID: id) else {
            nextPromptLogger.debug("prompt \(turn.promptID) ineligible: input blocked")
            return nil
        }
        guard let native = NSApp.keyWindow?.firstResponder as? ACPNSTextView else {
            nextPromptLogger.debug("prompt \(turn.promptID) ineligible: composer is not first responder")
            return nil
        }
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
        // Requests can queue behind a native drain. The async state observer
        // may still carry .unloading after enable/retry has established readiness;
        // consuming a completed turn here would permanently lose its suggestion.
        environment.isRuntimeAvailable = nextPromptInferenceState != .unavailable &&
            nextPromptInferenceState != .retryRequired
        environment.hasForkOrDelegationWork = environment.hasForkOrDelegationWork || nextPromptHasDelegatedWork(parentID: session.id)
        environment.composerEpoch = nextPromptComposerEpochs[session.incarnation, default: 0]
        environment.settingsGeneration = nextPromptSettingsGeneration
        environment.modelGeneration = localTextModelGeneration
        return .live(session: session, turn: turn, environment: environment)
    }
}
