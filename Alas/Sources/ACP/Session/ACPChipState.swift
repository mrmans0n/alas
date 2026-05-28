import Foundation

/// The composer-facing capability state. One value per canonical chip:
/// nil means the chip is hidden for this agent / not yet populated.
struct ACPChipState: Equatable {
    var models: ChipSpec?
    var mode: ChipSpec?
    var thinking: ChipSpec?
    var autoRun: ACPAgentProfiles.AutoRunSupport
}

/// A single chip's data, plus a tag remembering where it came from so the
/// composer knows which RPC to send when the user changes the selection.
struct ChipSpec: Equatable {
    enum Source: Equatable {
        case modes                           // dispatch via session/set_mode
        case configOption(id: String)        // dispatch via session/set_config_option
        case models                          // dispatch via session/set_model
    }
    let source: Source
    let options: [Item]
    let currentId: String?

    struct Item: Equatable, Hashable {
        let id: String
        let name: String
        let description: String?
    }
}

extension ACPChipState {
    /// Pure normalization. Inputs are raw `ACPSession` fields + the agent id.
    /// Output is the four-slot chip state. No side effects, no protocol calls.
    static func normalize(
        agentId: String,
        availableModels: [ACPModelInfo],
        currentModel: String?,
        availableModes: [ACPModeInfo],
        currentMode: String?,
        configOptions: [ACPConfigOption]
    ) -> ACPChipState {
        let routing = ACPAgentProfiles.routing(for: agentId)

        let models: ChipSpec? = availableModels.isEmpty ? nil : ChipSpec(
            source: .models,
            options: availableModels.map {
                ChipSpec.Item(id: $0.id, name: $0.name, description: $0.description)
            },
            currentId: currentModel)

        let mode = chipSpec(from: routing.modeSource,
                            modes: availableModes,
                            currentMode: currentMode,
                            configOptions: configOptions,
                            agentId: agentId)
        let thinking = chipSpec(from: routing.thinkingSource,
                                modes: availableModes,
                                currentMode: currentMode,
                                configOptions: configOptions,
                                agentId: agentId)
        return ACPChipState(models: models, mode: mode,
                            thinking: thinking, autoRun: routing.autoRun)
    }

    private static func chipSpec(
        from source: ACPAgentProfiles.ChipSource,
        modes: [ACPModeInfo],
        currentMode: String?,
        configOptions: [ACPConfigOption],
        agentId: String
    ) -> ChipSpec? {
        switch source {
        case .none:
            return nil
        case .modes:
            guard !modes.isEmpty else { return nil }
            return ChipSpec(
                source: .modes,
                options: modes.map {
                    ChipSpec.Item(id: $0.id, name: $0.name, description: $0.description)
                },
                currentId: currentMode)
        case .configOption(let id):
            return selectOption(id: id, in: configOptions)
        case .heuristic:
            guard let id = ACPAgentProfiles.heuristicThinkingId(from: configOptions) else {
                return nil
            }
            return selectOption(id: id, in: configOptions)
        }
    }

    private static func selectOption(id: String,
                                     in configOptions: [ACPConfigOption]) -> ChipSpec? {
        guard let opt = configOptions.first(where: { $0.id == id }),
              opt.type == "select", !opt.options.isEmpty else {
            return nil
        }
        return ChipSpec(
            source: .configOption(id: opt.id),
            options: opt.options.map {
                ChipSpec.Item(id: $0.id, name: $0.name, description: $0.description)
            },
            currentId: opt.currentValue)
    }
}
