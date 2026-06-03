import Foundation

/// The composer-facing capability state. One value per canonical chip:
/// nil means the chip is hidden for this agent / not yet populated.
struct ACPChipState: Equatable {
    var models: ChipSpec?
    var mode: ChipSpec?
    var thinking: ChipSpec?
    var parameters: [ACPParameterChip]
    var autoRun: ACPAgentProfiles.AutoRunSupport
}

/// Additional select config options returned by parameterized model pickers.
/// These are not canonical ACP chips, but still need to stay reachable.
struct ACPParameterChip: Identifiable, Equatable {
    let id: String
    let label: String
    let spec: ChipSpec
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
        let consumedConfigIds = Set([
            configOptionId(from: models),
            configOptionId(from: mode),
            configOptionId(from: thinking),
        ].compactMap { $0 })
        let parameters = parameterChips(from: configOptions,
                                        excluding: consumedConfigIds)
        var result = ACPChipState(models: models, mode: mode,
                                  thinking: thinking, parameters: parameters,
                                  autoRun: routing.autoRun)

        // Cursor encodes thinking as `[effort=…]` / `[thinking=…]` suffixes
        // on model variant ids. When the standard thinking heuristic finds
        // nothing (i.e. no proper `thought_level` configOption was
        // advertised), derive Model + Thinking chips from the variant list.
        // Guards ensure the overlay never fires for other agents or for
        // future-fixed Cursor builds that ship a real config option.
        if agentId == "cursor-agent", result.thinking == nil {
            let derived = CursorModelVariants.derive(
                availableModels: availableModels,
                currentModel: currentModel)
            // Don't clobber a `category: "model"` configOption-sourced models
            // chip — that path means Cursor advertised a proper model selector
            // and we should respect it. Only overlay onto the legacy `.model`
            // source (or when there's no models chip at all).
            if let m = derived.model,
               result.models == nil || result.models?.source == .model {
                result.models = m
            }
            if let t = derived.thinking { result.thinking = t }
        }
        return result
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
        guard let opt = options.first(where: {
            guard let c = $0.category else { return false }
            return categoryMatches(c, category)
        }) else { return nil }
        return selectOption(id: opt.id, in: options)
    }

    private static func parameterChips(
        from options: [ACPConfigOption],
        excluding consumedIds: Set<String>
    ) -> [ACPParameterChip] {
        options.compactMap { opt in
            guard opt.type == "select", !opt.options.isEmpty,
                  !consumedIds.contains(opt.id),
                  !isCanonicalCategory(opt.category) else {
                return nil
            }

            return ACPParameterChip(
                id: opt.id,
                label: opt.name.isEmpty ? opt.id.capitalized : opt.name,
                spec: ChipSpec(
                    source: .configOption(id: opt.id),
                    options: opt.options.map {
                        ChipSpec.Item(id: $0.id, name: $0.name, description: $0.description)
                    },
                    currentId: opt.currentValue))
        }
    }

    private static func configOptionId(from spec: ChipSpec?) -> String? {
        guard case .configOption(let id)? = spec?.source else { return nil }
        return id
    }

    private static func isCanonicalCategory(_ category: String?) -> Bool {
        guard let category else { return false }
        return categoryMatches(category, "model")
            || categoryMatches(category, "mode")
            || categoryMatches(category, "thought_level")
            || categoryMatches(category, "ThoughtLevel")
    }

    private static func categoryMatches(_ actual: String, _ expected: String) -> Bool {
        actual == expected || actual == expected.prefix(1).uppercased() + expected.dropFirst()
    }
}
