import AppKit
import Combine
import Foundation

/// Owns observer lifetimes without retaining AppState through long-lived streams.
final class LocalTextObservers {
    var tasks: [Task<Void, Never>] = []
    var notifications: [AnyCancellable] = []
    var managers: [SessionOwnerID: AnyCancellable] = [:]
    var sessions: [UUID: [AnyCancellable]] = [:]
    var pressure: DispatchSourceMemoryPressure?
    var modelStarted = false
    var nextPromptStarted = false
    var pendingReadiness: Set<Task<Void, Never>> = []

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        pendingReadiness.forEach { $0.cancel() }
        pendingReadiness.removeAll()
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
    var localTextModelAvailable: Bool {
        localTextSupported && config.localTextModelEnabled
            && !localTextModelDisableSavePending && !localTextModelPermissionChangeInProgress
            && !localTextRemovalInProgress && !nextPromptShuttingDown
            && localTextModelState == .ready
    }

    func startLocalTextObservers() {
        guard localTextSupported, config.localTextModelEnabled else { return }
        ensureLocalTextObserversStarted()
        let permission = localTextPermissionGeneration
        let nextPromptGeneration = nextPromptSettingsGeneration
        let summaryGeneration = sessionSummarySettingsGeneration
        let inspection = Task { [weak self] in
            guard let self else { return }
            await self.inspectLocalTextModel()
            guard permission == self.localTextPermissionGeneration, self.localTextModelAvailable else { return }
            if nextPromptGeneration == self.nextPromptSettingsGeneration {
                self.nextPromptRuntimeEnabled = self.config.nextPromptSuggestionsEnabled && !self.nextPromptDisableSavePending
            }
            if summaryGeneration == self.sessionSummarySettingsGeneration {
                self.sessionSummariesRuntimeEnabled = self.config.sessionSummariesEnabled && !self.sessionSummaryDisableSavePending
            }
        }
        localTextObservers.pendingReadiness.insert(inspection)
        localTextObservers.tasks.append(inspection)
    }

    func ensureLocalTextObserversStarted() {
        guard !nextPromptShuttingDown else { return }
        if !localTextObservers.modelStarted {
            localTextObservers.modelStarted = true
            let model = localTextModelStore
            localTextObservers.tasks.append(Task { [weak self] in
                for await value in await model.states() {
                    guard !Task.isCancelled else { return }
                    self?.updateLocalTextModelState(value)
                }
            })
        }
        guard localTextSupported, config.localTextModelEnabled, !localTextModelDisableSavePending else { return }
        // Fallback-only callers also need native drain when permission is revoked.
        localTextRuntimeStarted = true
        if localTextObservers.pressure == nil {
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            pressure.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.invalidateAllNextPromptContexts()
                    self.sessionSummaryCoordinator.teardown()
                    Task { await self.localTextInference.cancelAndUnload() }
                }
            }
            localTextObservers.pressure = pressure
            pressure.resume()
        }
        ensureNextPromptObserversStarted()
    }

    func trackLocalTextReadiness(_ preparation: @escaping @MainActor () async -> Void) async {
        let task = Task { await preparation() }
        localTextObservers.pendingReadiness.insert(task)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        localTextObservers.pendingReadiness.remove(task)
    }

    func waitForLocalTextReadiness() async {
        while let pending = localTextObservers.pendingReadiness.first {
            await pending.value
            localTextObservers.pendingReadiness.remove(pending)
        }
    }

    func inspectLocalTextModel() async {
        let permission = localTextPermissionGeneration
        await localTextModelStore.inspect()
        let generation = localTextModelGeneration
        let value = await localTextReadModelState()
        guard permission == localTextPermissionGeneration, !nextPromptShuttingDown,
              !localTextRemovalInProgress,
              generation == localTextModelGeneration || value == localTextModelState else { return }
        updateLocalTextModelState(value)
    }

    func inspectLocalTextModelOnSettingsAppearance() async {
        guard !localTextSettingsInspected, !nextPromptShuttingDown else { return }
        localTextSettingsInspected = true
        ensureLocalTextObserversStarted()
        await inspectLocalTextModel()
    }

    func updateLocalTextModelState(_ value: LocalTextModelState) {
        guard value != localTextModelState else { return }
        if localTextSupported {
            if config.nextPromptSuggestionsEnabled || nextPromptRuntimeEnabled { nextPromptCoordinator.invalidateAll() }
            if config.sessionSummariesEnabled || sessionSummariesRuntimeEnabled { sessionSummaryCoordinator.teardown() }
        }
        localTextModelGeneration &+= 1
        localTextModelState = value
        if value != .ready {
            nextPromptRuntimeEnabled = false
            sessionSummariesRuntimeEnabled = false
        }
    }

    func setLocalTextModelEnabled(_ enabled: Bool) async {
        guard !nextPromptShuttingDown, !localTextRemovalInProgress,
              !localTextModelPermissionChangeInProgress else { return }
        if enabled {
            guard localTextSupported, !localTextModelDisableSavePending else { return }
        }
        let permission: UInt64
        do {
            localTextModelPermissionChangeInProgress = true
            defer { localTextModelPermissionChangeInProgress = false }
            if !enabled {
                _ = await revokeLocalTextPermission()
                return
            }
            let previous = config.localTextModelEnabled
            config.localTextModelEnabled = true
            guard saveConfig() else {
                config.localTextModelEnabled = previous
                localTextModelSettingsError = "Could not save model permission. No download was started."
                return
            }
            localTextModelSettingsError = nil
            localTextPermissionGeneration &+= 1
            permission = localTextPermissionGeneration
            ensureLocalTextObserversStarted()
            await trackLocalTextReadiness { await self.inspectLocalTextModel() }
            guard permission == localTextPermissionGeneration, !nextPromptShuttingDown else { return }
        }
        await restoreLocalTextFeatures(permission: permission)
    }

    func retryLocalTextModelSettings() async {
        await setLocalTextModelEnabled(localTextModelDisableSavePending ? false : config.localTextModelEnabled)
    }

    /// The only permission-granting action that can transfer model files.
    func downloadLocalTextModel() async {
        guard localTextSupported, !nextPromptShuttingDown, !localTextRemovalInProgress,
              !localTextModelPermissionChangeInProgress, !localTextModelDisableSavePending else { return }
        if !config.localTextModelEnabled {
            config.localTextModelEnabled = true
            guard saveConfig() else {
                config.localTextModelEnabled = false
                localTextModelSettingsError = "Could not save download consent. No model files were downloaded."
                return
            }
            localTextPermissionGeneration &+= 1
        }
        localTextModelSettingsError = nil
        localTextRemovalFailure = nil
        ensureLocalTextObserversStarted()
        if let installation = localTextInstallation {
            await installation.value
            return
        }
        let permission = localTextPermissionGeneration
        let store = localTextModelStore
        let installation = Task { await store.install() }
        localTextInstallation = installation
        await trackLocalTextReadiness {
            await installation.value
            guard self.localTextInstallation == installation, permission == self.localTextPermissionGeneration,
                  !self.nextPromptShuttingDown, !self.localTextRemovalInProgress else { return }
            let generation = self.localTextModelGeneration
            let value = await self.localTextReadModelState()
            guard self.localTextInstallation == installation, permission == self.localTextPermissionGeneration,
                  !self.nextPromptShuttingDown, !self.localTextRemovalInProgress else { return }
            self.localTextInstallation = nil
            guard generation == self.localTextModelGeneration || value == self.localTextModelState else { return }
            self.updateLocalTextModelState(value)
            await self.restoreLocalTextFeatures(permission: permission)
        }
    }

    func retryLocalTextModelDownload() async { await downloadLocalTextModel() }

    func cancelLocalTextDownload() async {
        guard let installation = localTextInstallation else { return }
        nextPromptSettingsGeneration &+= 1
        sessionSummarySettingsGeneration &+= 1
        nextPromptRuntimeEnabled = false
        sessionSummariesRuntimeEnabled = false
        localTextInstallation = nil
        installation.cancel()
        await localTextModelStore.cancelDownload()
        await installation.value
        let generation = localTextModelGeneration
        let value = await localTextReadModelState()
        guard generation == localTextModelGeneration || value == localTextModelState else { return }
        updateLocalTextModelState(value)
    }

    private func restoreLocalTextFeatures(permission: UInt64) async {
        guard permission == localTextPermissionGeneration, localTextModelAvailable else { return }
        if config.nextPromptSuggestionsEnabled, !nextPromptDisableSavePending { await retryNextPromptSuggestions() }
        guard permission == localTextPermissionGeneration, localTextModelAvailable else { return }
        if config.sessionSummariesEnabled, !sessionSummaryDisableSavePending { await retrySessionSummarySettings() }
    }

    /// Suppress publication before saving, then drain only local-model work.
    private func revokeLocalTextPermission() async -> Bool {
        localTextPermissionGeneration &+= 1
        beginNextPromptSettingsChange()
        beginSessionSummarySettingsChange()
        qwenTitleRequests.cancelAll()
        localTextObservers.pendingReadiness.forEach { $0.cancel() }
        localTextObservers.pendingReadiness.removeAll()
        let previous = config.localTextModelEnabled
        config.localTextModelEnabled = false
        let saved = saveConfig()
        localTextModelDisableSavePending = !saved
        if !saved { config.localTextModelEnabled = previous }
        localTextModelSettingsError = saved ? nil
            : "Local model use is off for this session, but disabling could not be saved. Retry before quitting."
        if localTextInstallation != nil { await cancelLocalTextDownload() }
        if localTextRuntimeStarted {
            await nextPromptCoordinator.shutdown()
            if nextPromptInferenceOverride != nil { await nextPromptInference.cancelAndUnload() }
            await localTextInference.cancelAndUnload()
        }
        return saved
    }

    var canRemoveLocalTextModel: Bool {
        !nextPromptShuttingDown && !localTextRemovalInProgress && !localTextModelPermissionChangeInProgress
    }

    func removeLocalTextModel() async {
        guard canRemoveLocalTextModel else { return }
        localTextRemovalInProgress = true
        defer { localTextRemovalInProgress = false }
        guard await revokeLocalTextPermission() else { return }
        do {
            try await localTextModelStore.remove()
            localTextRemovalFailure = nil
            updateLocalTextModelState(await localTextReadModelState())
        } catch {
            let failure = LocalTextModelFailure.safe(error)
            localTextRemovalFailure = failure == .busy ? .inUse : failure
        }
    }

    func retryOnDeviceAIHelperSettings() {
        onDeviceAIHelperSettingsError = saveConfig() ? nil
            : "Could not save helper settings. Changes apply only to this session. Retry before quitting."
    }

    func shutdownLocalTextFeatures() async {
        nextPromptShuttingDown = true
        localTextPermissionGeneration &+= 1
        beginNextPromptSettingsChange()
        beginSessionSummarySettingsChange()
        qwenTitleRequests.cancelAll()
        let installation = localTextInstallation
        localTextInstallation = nil
        installation?.cancel()
        await localTextModelStore.cancelDownload()
        await installation?.value
        if localTextRuntimeStarted {
            await nextPromptCoordinator.shutdown()
            if nextPromptInferenceOverride != nil { await nextPromptInference.cancelAndUnload() }
            await localTextInference.cancelAndUnload()
        }
        localTextObservers.cancel()
    }
}
