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
        case mode                            // dispatch via session/set_mode
        case configOption(id: String)        // dispatch via session/set_config_option
        case model                           // dispatch via session/set_model
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

        // Prefer a `category: "model"` configOption when the agent advertises
        // one (the stabilized ACP path); fall back to the legacy
        // `availableModels` list. Either way the chip dispatches via the
        // source tag on `ChipSpec`.
        let models: ChipSpec? =
            chipFromCategoryConfigOption(category: "model", in: configOptions)
            ?? (availableModels.isEmpty ? nil : ChipSpec(
                source: .model,
                options: availableModels.map {
                    ChipSpec.Item(id: $0.id, name: $0.name, description: $0.description)
                },
                currentId: currentModel))

        // Same precedence rule for Mode: a `category: "mode"` configOption
        // wins over the legacy `availableModes` list.
        let mode = chipFromCategoryConfigOption(category: "mode", in: configOptions)
            ?? chipSpec(from: routing.modeSource,
                        modes: availableModes,
                        currentMode: currentMode,
                        configOptions: configOptions)
        let thinking = chipSpec(from: routing.thinkingSource,
                                modes: availableModes,
                                currentMode: currentMode,
                                configOptions: configOptions)
        return ACPChipState(models: models, mode: mode,
                            thinking: thinking, autoRun: routing.autoRun)
    }

    private static func chipSpec(
        from source: ACPAgentProfiles.ChipSource,
        modes: [ACPModeInfo],
        currentMode: String?,
        configOptions: [ACPConfigOption]
    ) -> ChipSpec? {
        switch source {
        case .none:
            return nil
        case .mode:
            guard !modes.isEmpty else { return nil }
            return ChipSpec(
                source: .mode,
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

    /// Finds a configOption that advertises itself for the given category
    /// (e.g. `"model"`, `"mode"`). Older drafts capitalized the marker, so
    /// the caller accepts both forms by listing each spelling. Returns nil
    /// when no matching option exists, in which case the caller falls back
    /// to the legacy list.
    private static func chipFromCategoryConfigOption(
        category: String,
        in options: [ACPConfigOption]
    ) -> ChipSpec? {
        let accepted: Set<String> = [category, category.prefix(1).uppercased() + category.dropFirst()]
        guard let opt = options.first(where: {
            guard let c = $0.category else { return false }
            return accepted.contains(c)
        }) else { return nil }
        return selectOption(id: opt.id, in: options)
    }
}
