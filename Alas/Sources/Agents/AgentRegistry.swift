/// Persisted per-built-in agent state. Built-in static knowledge
/// (display name, args, flags, logo) lives in `AgentBuiltins.catalog`;
/// only what the user can change is stored on disk.
struct BuiltinAgentState: Codable, Equatable {
    var isEnabled: Bool
    var binaryOverride: String?
}

/// Runtime view over the agent catalog. Built-ins come first (in catalog
/// order) with overlay state applied; customs are appended in their
/// persisted order. Filtered accessors honour install detection.
struct AgentRegistry: Equatable {
    let agents: [AgentDefinition]

    /// Set of agent ids whose binary was found on PATH (or whose
    /// `binaryOverride` resolves to an executable file). Stored so
    /// `installed()` / `enabled()` are pure.
    private let installedIds: Set<String>

    init(
        builtinState: [String: BuiltinAgentState],
        customs: [AgentDefinition],
        installedIds: Set<String>
    ) {
        var out: [AgentDefinition] = []
        for var builtin in AgentBuiltins.catalog {
            let prefersEnabled: Bool
            if let state = builtinState[builtin.id] {
                prefersEnabled = state.isEnabled
                builtin.binaryOverride = state.binaryOverride
            } else {
                prefersEnabled = builtin.isEnabled
            }
            builtin.isEnabled = prefersEnabled && installedIds.contains(builtin.id)
            out.append(builtin)
        }
        for var c in customs {
            c.isEnabled = c.isEnabled && installedIds.contains(c.id)
            out.append(c)
        }
        self.agents = out
        self.installedIds = installedIds
    }

    /// All agents whose binary was detected on PATH (or via
    /// `binaryOverride`), regardless of `isEnabled`. Disabled agents are
    /// still in this list — call `enabled()` for the picker-eligible
    /// subset.
    func installed() -> [AgentDefinition] {
        agents.filter { installedIds.contains($0.id) }
    }

    /// Picker-eligible agents: installed AND not user-disabled. Note
    /// that `isEnabled` is already clamped against install state in
    /// `init`, so the explicit `installedIds.contains` check is
    /// redundant but kept defensively.
    func enabled() -> [AgentDefinition] {
        agents.filter { $0.isEnabled && installedIds.contains($0.id) }
    }
}
