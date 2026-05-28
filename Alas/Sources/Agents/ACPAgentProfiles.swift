/// Per-agent routing: where each canonical chip pulls its options from.
///
/// ACP doesn't dictate what `availableModes` *means* — claude uses it for
/// permission presets, opencode uses it for agent persona, pi uses it for
/// thinking level. This table translates between what each agent advertises
/// and the four canonical UI slots (Model / Mode / Thinking / Auto-run).
enum ACPAgentProfiles {
    struct Routing: Equatable {
        var modeSource: ChipSource
        var thinkingSource: ChipSource
        var autoRun: AutoRunSupport
    }

    /// Where a chip's options come from.
    enum ChipSource: Equatable {
        case modes                           // ACPSession.availableModes
        case configOption(id: String)        // a specific configOption by id
        case heuristic                       // unknown-agent fallback (see below)
        case none                            // chip is hidden for this agent
    }

    static func routing(for agentId: String) -> Routing {
        switch agentId {
        case "claude":
            return .init(modeSource: .modes,
                         thinkingSource: .configOption(id: "effort"),
                         autoRun: .supported)
        case "codex":
            return .init(modeSource: .modes,
                         thinkingSource: .configOption(id: "reasoning_effort"),
                         autoRun: .supported)
        case "opencode":
            return .init(modeSource: .modes,
                         thinkingSource: .configOption(id: "effort"),
                         autoRun: .supported)
        case "pi":
            return .init(modeSource: .none,
                         thinkingSource: .modes,
                         autoRun: .ignored)
        default:
            return .init(modeSource: .modes,
                         thinkingSource: .heuristic,
                         autoRun: .supported)
        }
    }

    /// The unknown-agent Thinking heuristic: pick a configOption whose id
    /// matches a known thinking name OR whose category is "ThoughtLevel".
    /// Returns nil if no candidate exists.
    static func heuristicThinkingId(from options: [ACPConfigOption]) -> String? {
        let knownIds: Set<String> = ["effort", "reasoning_effort", "thinking", "thinking_level"]
        if let byId = options.first(where: { knownIds.contains($0.id) }) { return byId.id }
        if let byCategory = options.first(where: { $0.category == "ThoughtLevel" }) {
            return byCategory.id
        }
        return nil
    }
}

/// Whether the local Auto-run toggle has any effect on this agent. Used to
/// decide whether the tooltip should warn the user.
enum AutoRunSupport: Equatable {
    case supported    // agent uses ACP requestPermission; toggle skips prompts
    case ignored      // agent doesn't request permissions; toggle is a no-op
}
