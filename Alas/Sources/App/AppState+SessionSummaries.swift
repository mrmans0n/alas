import Foundation

extension AppState {
    func enableSessionSummaries() async {
        guard localTextSupported, !nextPromptShuttingDown, !sessionSummaryDisableSavePending else { return }
        let previous = config.sessionSummariesEnabled
        beginSessionSummarySettingsChange()
        let generation = sessionSummarySettingsGeneration
        config.sessionSummariesEnabled = true
        guard saveConfig() else {
            config.sessionSummariesEnabled = previous
            sessionSummarySettingsError = "Could not save session-summary settings. Summaries remain off."
            return
        }
        ensureLocalTextObserversStarted()
        await prepareSessionSummaries(generation: generation)
    }

    func retrySessionSummarySettings() async {
        if sessionSummaryDisableSavePending {
            await disableSessionSummaries()
            return
        }
        guard config.sessionSummariesEnabled, localTextSupported, !nextPromptShuttingDown else { return }
        beginSessionSummarySettingsChange()
        await prepareSessionSummaries(generation: sessionSummarySettingsGeneration)
    }

    func disableSessionSummaries() async {
        beginSessionSummarySettingsChange()
        let previous = config.sessionSummariesEnabled
        config.sessionSummariesEnabled = false
        if saveConfig() {
            sessionSummaryDisableSavePending = false
            sessionSummarySettingsError = nil
        } else {
            config.sessionSummariesEnabled = previous
            sessionSummaryDisableSavePending = true
            sessionSummarySettingsError =
                "Could not save disabling. Retry before quitting or summaries may turn on again after relaunch."
        }
    }

    private func prepareSessionSummaries(generation: UInt64) async {
        localTextRuntimeStarted = true
        await inspectLocalTextModel()
        guard generation == sessionSummarySettingsGeneration, !nextPromptShuttingDown else { return }
        if localTextModelState != .ready {
            let install = localTextInstallation ?? Task { await localTextModelStore.install() }
            localTextInstallation = install
            await install.value
            guard generation == sessionSummarySettingsGeneration, !nextPromptShuttingDown else { return }
            localTextInstallation = nil
            updateLocalTextModelState(await localTextReadModelState())
        }
        guard generation == sessionSummarySettingsGeneration,
              config.sessionSummariesEnabled,
              localTextModelState == .ready,
              !nextPromptShuttingDown else { return }
        sessionSummariesRuntimeEnabled = true
    }

    private func beginSessionSummarySettingsChange() {
        sessionSummaryCoordinator.teardown()
        sessionSummarySettingsGeneration &+= 1
        sessionSummariesRuntimeEnabled = false
        if !sessionSummaryDisableSavePending { sessionSummarySettingsError = nil }
        localTextRemovalFailure = nil
    }
}
