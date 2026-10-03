import Foundation

extension AppState {
    func enableSessionSummaries() async {
        guard localTextSupported, !nextPromptShuttingDown, !sessionSummaryDisableSavePending,
              !localTextRemovalInProgress else { return }
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
        await trackLocalTextReadiness { await self.prepareSessionSummaries(generation: generation) }
    }

    func retrySessionSummarySettings() async {
        guard !localTextRemovalInProgress else { return }
        if sessionSummaryDisableSavePending {
            await disableSessionSummaries()
            return
        }
        guard config.sessionSummariesEnabled, localTextSupported, !nextPromptShuttingDown else { return }
        beginSessionSummarySettingsChange()
        let generation = sessionSummarySettingsGeneration
        await trackLocalTextReadiness { await self.prepareSessionSummaries(generation: generation) }
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
        guard generation == sessionSummarySettingsGeneration,
              config.sessionSummariesEnabled,
              localTextModelAvailable, !sessionSummaryDisableSavePending,
              !nextPromptShuttingDown else { return }
        sessionSummariesRuntimeEnabled = true
    }

    func beginSessionSummarySettingsChange() {
        if localTextRuntimeStarted { sessionSummaryCoordinator.teardown() }
        sessionSummarySettingsGeneration &+= 1
        sessionSummariesRuntimeEnabled = false
        if !sessionSummaryDisableSavePending { sessionSummarySettingsError = nil }
        localTextRemovalFailure = nil
    }
}
