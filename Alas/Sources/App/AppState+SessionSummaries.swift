import Foundation
import os

private let sessionSummariesLogger = Logger(subsystem: "io.nlopez.alas", category: "session-summaries")

extension AppState {
    func enableSessionSummaries() async {
        await awaitSessionSummaryCleanup()
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
        await awaitSessionSummaryCleanup()
        guard config.sessionSummariesEnabled, localTextSupported, !nextPromptShuttingDown,
              !localTextRemovalInProgress, !sessionSummaryDisableSavePending else { return }
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
            dropAllRecapPrecompute()
            let coordinator = sessionSummaryCoordinator
            coordinator.invalidatePersistence()
            let stores = core.sessionManagers.values.map(\.persistence)
            let previousCleanup = sessionSummaryCleanupTask
            // Re-enabling awaits this, so the sweep cannot delete new summaries.
            sessionSummaryCleanupTask = Task {
                await previousCleanup?.value
                await coordinator.clearPersistedSummaries(in: stores)
                // Session databases are per worktree, and most are not loaded.
                await Task.detached(priority: .utility) { Self.clearSessionSummariesOnDisk() }.value
            }
        } else {
            config.sessionSummariesEnabled = previous
            sessionSummaryDisableSavePending = true
            sessionSummarySettingsError =
                "Could not save disabling. Retry before quitting or summaries may turn on again after relaunch."
        }
    }

    /// Waits for the cleanup of every earlier disable, including ones started
    /// while waiting.
    private func awaitSessionSummaryCleanup() async {
        while let cleanup = sessionSummaryCleanupTask {
            await cleanup.value
            if sessionSummaryCleanupTask == cleanup { sessionSummaryCleanupTask = nil }
        }
    }

    /// Clears the summaries in every worktree session database on disk.
    nonisolated private static func clearSessionSummariesOnDisk() {
        let root = Paths.acpSessionsRoot
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "sqlite" {
            do {
                try ACPSessionStore.deleteAllSessionSummaries(path: file.path)
            } catch {
                sessionSummariesLogger.error("clearing summaries in \(file.lastPathComponent, privacy: .public) failed: \(String(describing: error))")
            }
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
