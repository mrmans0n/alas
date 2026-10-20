import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// The composer-facing capability state. One value per canonical chip:
/// nil means the chip is hidden for this agent / not yet populated.
public struct ACPChipState: Equatable, Sendable {
    public var models: ChipSpec?
    public var mode: ChipSpec?
    public var thinking: ChipSpec?
    public var parameters: [ACPParameterChip]
    public var autoRun: ACPAgentProfiles.AutoRunSupport

    public init(models: ChipSpec? = nil, mode: ChipSpec? = nil, thinking: ChipSpec? = nil, parameters: [ACPParameterChip], autoRun: ACPAgentProfiles.AutoRunSupport) {
        self.models = models
        self.mode = mode
        self.thinking = thinking
        self.parameters = parameters
        self.autoRun = autoRun
    }
}

/// Additional select config options returned by parameterized model pickers.
/// These are not canonical ACP chips, but still need to stay reachable.
public struct ACPParameterChip: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let presentation: ACPParameterChipPresentation
    public let spec: ChipSpec

    public init(id: String, label: String, presentation: ACPParameterChipPresentation, spec: ChipSpec) {
        self.id = id
        self.label = label
        self.presentation = presentation
        self.spec = spec
    }
}

public enum ACPParameterChipPresentation: Equatable, Sendable {
    case standard
    case cursorContextWindow
    case fastMode
}

/// A single chip's data, plus a tag remembering where it came from so the
/// composer knows which RPC to send when the user changes the selection.
public struct ChipSpec: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case mode                            // dispatch via session/set_mode
        case configOption(id: String)        // dispatch via session/set_config_option
        case model                           // dispatch via session/set_model
    }
    public let source: Source
    public let options: [Item]
    public let currentId: String?

    public struct Item: Equatable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let description: String?
        public let kind: ACPModeKind?

        public init(id: String, name: String, description: String?, kind: ACPModeKind? = nil) {
            self.id = id
            self.name = name
            self.description = description
            self.kind = kind
        }
    }

    public init(source: Source, options: [Item], currentId: String?) {
        self.source = source
        self.options = options
        self.currentId = currentId
    }
}

extension ACPChipState {
    /// Pure normalization. Inputs are raw `ACPSession` fields + the agent id.
    /// Output is the four-slot chip state. No side effects, no protocol calls.
    public static func normalize(
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
                                        agentId: agentId,
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
                    ChipSpec.Item(id: $0.id, name: $0.name, description: $0.description, kind: $0.kind)
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
        guard let opt = configOptions.first(where: { $0.id == id && isUsableSelectOption($0) }) else {
            return nil
        }
        return ChipSpec(
            source: .configOption(id: opt.id),
            options: opt.options.map {
                ChipSpec.Item(id: $0.id, name: $0.name, description: $0.description, kind: $0.kind)
            },
            currentId: opt.currentStringValue)
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
            guard isUsableSelectOption($0) else { return false }
            guard let c = $0.category else { return false }
            return categoryMatches(c, category)
        }) else { return nil }
        return selectOption(id: opt.id, in: options)
    }

    private static func isUsableSelectOption(_ option: ACPConfigOption) -> Bool {
        option.type == "select" && !option.options.isEmpty
    }

    private static func parameterChips(
        from options: [ACPConfigOption],
        agentId: String,
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
                presentation: presentation(for: opt, agentId: agentId),
                spec: ChipSpec(
                    source: .configOption(id: opt.id),
                    options: opt.options.map {
                        ChipSpec.Item(id: $0.id, name: $0.name, description: $0.description, kind: $0.kind)
                    },
                    currentId: opt.currentStringValue))
        }
    }

    private static func presentation(
        for option: ACPConfigOption,
        agentId: String
    ) -> ACPParameterChipPresentation {
        if isFastModeConfigOption(option) {
            return .fastMode
        }

        guard agentId == "cursor-agent" else { return .standard }

        let id = option.id.lowercased()
        let name = option.name.lowercased()
        if id == "context" || id == "context_window" || name == "context window" {
            return .cursorContextWindow
        }
        return .standard
    }

    public static func isFastModeConfigOption(_ option: ACPConfigOption) -> Bool {
        let id = normalizedFastModeToken(option.id)
        let name = normalizedFastModeToken(option.name)
        return id == "fast" || id == "fastmode" || name == "fast" || name == "fastmode"
    }

    private static func normalizedFastModeToken(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
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
