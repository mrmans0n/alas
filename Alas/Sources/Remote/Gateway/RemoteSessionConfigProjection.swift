import Foundation

/// The single place an `ACPSession` becomes a `sessionConfig` frame. The
/// subscribe reply (`AppState.sessionConfig(for:)`) and the gateway's change
/// emitter both call it, so the two can never drift.
@MainActor
enum RemoteSessionConfigProjection {
    static func config(sessionId: String, session: ACPSession) -> RemoteSessionConfig {
        var config = RemoteSessionConfig(
            sessionId: sessionId,
            models: session.availableModels.map { RemoteModelInfo(id: $0.id, name: $0.name) },
            modes: session.availableModes.map { RemoteModelInfo(id: $0.id, name: $0.name) },
            currentModel: session.currentModel,
            currentMode: session.currentMode,
            autoRunEnabled: session.autoRunEnabled,
            acceptsImages: session.promptCapabilities.image)
        config.chips = chips(session.chipState, configOptions: session.availableConfigOptions)
        config.supportsSteering = session.supportsSteering
        config.availableCommands = session.promptSuggestions.map {
            RemoteSlashCommand(command: $0.command, description: $0.description, hint: $0.hint)
        }
        config.usage = usage(context: session.contextUsage, modelName: session.currentModelDisplayName,
                             lastTurn: session.lastTurnQuota, cumulative: session.sessionQuotaTotal)
        config.supportsQueueReorder = true
        config.supportsMentions = true
        return config
    }

    /// Nil when there is nothing for the ring or its popover to show, so a
    /// viewer hides it exactly when the local composer would.
    nonisolated static func usage(
        context: ACPUsageInfo?, modelName: String?, lastTurn: ACPPromptQuota?, cumulative: ACPPromptQuota?
    ) -> RemoteUsage? {
        let usage = RemoteUsage(
            modelName: modelName,
            context: context.map {
                RemoteContextWindow(used: $0.used, size: $0.size, costAmount: $0.cost?.amount,
                                    costCurrency: $0.cost?.currency)
            },
            lastTurn: tokenRows(lastTurn),
            cumulative: tokenRows(cumulative))
        guard usage.context != nil || !usage.lastTurn.isEmpty || !usage.cumulative.isEmpty else { return nil }
        return usage
    }

    /// The rows `ACPContextUsageButton` lists: one per model, or a single
    /// total when the adapter sent no per-model breakdown.
    nonisolated private static func tokenRows(_ quota: ACPPromptQuota?) -> [RemoteTokenUsage] {
        guard let quota, quota.hasDisplayableContent else { return [] }
        if quota.modelUsage.isEmpty {
            return quota.tokenCount.map { [RemoteTokenUsage(label: "Total", tokens: $0.displayTotal)] } ?? []
        }
        return quota.modelUsage.map { RemoteTokenUsage(label: $0.model, tokens: $0.tokenCount.displayTotal) }
    }

    nonisolated static func chips(_ state: ACPChipState, configOptions: [ACPConfigOption]) -> RemoteChipState {
        RemoteChipState(
            model: state.models.map(chip),
            thinking: state.thinking.map(chip),
            mode: state.mode.map(chip),
            parameters: state.parameters.map {
                RemoteParameterChip(id: $0.id, label: $0.label,
                                    presentation: presentation($0.presentation), chip: chip($0.spec))
            },
            booleans: configOptions.compactMap { option in
                guard option.type == "boolean", let value = option.currentBoolValue else { return nil }
                return RemoteBooleanOption(id: option.id, name: option.name, value: value)
            },
            autoRun: state.autoRun == .ignored ? "ignored" : "supported")
    }

    nonisolated private static func chip(_ spec: ChipSpec) -> RemoteChip {
        let (source, configId): (String, String?) = switch spec.source {
        case .model: ("model", nil)
        case .mode: ("mode", nil)
        case .configOption(let id): ("config", id)
        }
        return RemoteChip(
            source: source, configId: configId,
            options: spec.options.map {
                RemoteChipOption(id: $0.id, name: $0.name, description: $0.description, kind: $0.kind?.rawValue)
            },
            currentId: spec.currentId)
    }

    nonisolated private static func presentation(_ value: ACPParameterChipPresentation) -> String {
        switch value {
        case .standard: "standard"
        case .cursorContextWindow: "cursorContextWindow"
        case .fastMode: "fastMode"
        }
    }
}
