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
            if let state = builtinState[builtin.id] {
                builtin.isEnabled = state.isEnabled
                builtin.binaryOverride = state.binaryOverride
            }
            out.append(builtin)
        }
        out.append(contentsOf: customs)
        self.agents = out
        self.installedIds = installedIds
    }

    func installed() -> [AgentDefinition] {
        agents.filter { installedIds.contains($0.id) }
    }

    func enabled() -> [AgentDefinition] {
        agents.filter { $0.isEnabled && installedIds.contains($0.id) }
    }
}
