import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasAgentKit
import AlasACP
import AlasSessions

/// The single place an `ACPSession` becomes a `sessionConfig` frame. The
/// subscribe reply (`AppState.sessionConfig(for:)`) and the gateway's change
/// emitter both call it, so the two can never drift.
@MainActor
public enum RemoteSessionConfigProjection: Sendable {
    public static func config(sessionId: String, session: ACPSession) -> RemoteSessionConfig {
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
        config.agentIssue = agentIssue(
            agentName: AgentBuiltins.entry(id: session.agentId)?.displayName ?? session.agentId,
            managedAdapter: ACPManagedAdapterDescriptor.descriptor(for: session.agentId) != nil,
            agentState: session.agentState, setupState: session.setupState, lastError: session.lastError)
        return config
    }

    /// Why the agent cannot run, in the words of the banner `ACPTabView`
    /// shows on the host: its error banner first, then the sign-in or
    /// setup nudge. Nil while the agent is fine or still connecting.
    public nonisolated static func agentIssue(
        agentName: String, managedAdapter: Bool,
        agentState: ACPSession.AgentState, setupState: ACPSession.SetupState, lastError: String?
    ) -> RemoteAgentIssue? {
        let kind: String
        let setupMessage: String?
        switch setupState {
        case .needsSetup(let reason):
            kind = "needsSetup"
            setupMessage = managedAdapter
                ? ACPSetupNudgeBannerCopy.idleMessage(mode: .install, agentDisplayName: agentName) : reason
        case .needsAuth(let methods, let reason):
            kind = "needsAuth"
            setupMessage = methods.contains(where: { $0.kind == .terminal })
                ? ACPAuthNudgeBannerCopy.message(agentDisplayName: agentName, reason: reason)
                : ACPAuthNudgeBannerCopy.unsupportedMessage(agentDisplayName: agentName)
        case .setupError(let reason):
            kind = "setupError"
            setupMessage = reason
        case .checking, .ready:
            guard case .failed = agentState else { return nil }
            kind = "failed"
            setupMessage = nil
        }
        if let lastError, !lastError.isEmpty { return RemoteAgentIssue(kind: kind, message: lastError) }
        if kind == "failed", case .failed(let reason) = agentState { return RemoteAgentIssue(kind: kind, message: reason) }
        return setupMessage.map { RemoteAgentIssue(kind: kind, message: $0) }
    }

    /// Nil when there is nothing for the ring or its popover to show, so a
    /// viewer hides it exactly when the local composer would.
    public nonisolated static func usage(
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

    public nonisolated static func chips(_ state: ACPChipState, configOptions: [ACPConfigOption]) -> RemoteChipState {
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
