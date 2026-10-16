/// Persisted per-built-in agent state. Built-in static knowledge
/// (display name, args, flags, logo) lives in `AgentBuiltins.catalog`;
/// only what the user can change is stored on disk.
public struct BuiltinAgentState: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var binaryOverride: String?
    public var extraTerminalArgs: [String]?
    /// "Disable native subagents" for new ACP sessions of this agent.
    /// Absent (nil) means off. Only honoured where
    /// `ACPNativeDelegationSupport` has a verified control.
    public var nativeSubagentsDisabled: Bool?
    /// "Session instructions" for new ACP sessions of this agent. Absent
    /// (nil) means none. See `ACPSessionInstructionsPolicy`.
    public var sessionInstructions: String?

    public init(
        isEnabled: Bool,
        binaryOverride: String? = nil,
        extraTerminalArgs: [String]? = nil,
        nativeSubagentsDisabled: Bool? = nil,
        sessionInstructions: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.binaryOverride = binaryOverride
        self.extraTerminalArgs = extraTerminalArgs
        self.nativeSubagentsDisabled = nativeSubagentsDisabled
        self.sessionInstructions = sessionInstructions
    }
}

extension AppConfig.Agents {
    /// Whether new ACP sessions of `agentID` start with native subagents
    /// disabled: the user's choice, clamped to agents with a verified control.
    public func nativeSubagentsDisabled(for agentID: String) -> Bool {
        builtinState[agentID]?.nativeSubagentsDisabled == true
            && ACPNativeDelegationSupport.resolve(agentID: agentID).canEnforce
    }

    /// The instructions new ACP sessions of `agentID` start with, or nil.
    public func sessionInstructions(for agentID: String) -> String? {
        guard ACPSessionInstructionsPolicy.isConfigurable(agentID: agentID) else { return nil }
        return ACPSessionInstructionsPolicy.normalized(builtinState[agentID]?.sessionInstructions)
    }
}

/// Runtime view over the agent catalog. Built-ins come first (in catalog
/// order) with overlay state applied; customs are appended in their
/// persisted order. Filtered accessors honour install detection.
public struct AgentRegistry: Equatable, Sendable {
    public let agents: [AgentDefinition]

    /// Set of agent ids whose binary was found on PATH (or whose
    /// `binaryOverride` resolves to an executable file). Stored so
    /// `installed()` / `enabled()` are pure.
    private let installedIds: Set<String>

    public init(
        builtinState: [String: BuiltinAgentState],
        customs: [AgentDefinition],
        installedIds: Set<String>
    ) {
        let configured = AgentConfiguredCatalog.all(
            builtinState: builtinState,
            customs: customs
        )
        self.agents = configured.map { agent in
            var localAgent = agent
            localAgent.isEnabled = agent.isEnabled && installedIds.contains(agent.id)
            return localAgent
        }
        self.installedIds = installedIds
    }

    /// All agents whose binary was detected on PATH (or via
    /// `binaryOverride`), regardless of `isEnabled`. Disabled agents are
    /// still in this list — call `enabled()` for the picker-eligible
    /// subset.
    public func installed() -> [AgentDefinition] {
        agents.filter { installedIds.contains($0.id) }
    }

    /// Picker-eligible agents: installed AND not user-disabled.
    /// `isEnabled` is clamped against install state in `init`, so a
    /// simple `isEnabled` filter suffices.
    public func enabled() -> [AgentDefinition] {
        agents.filter { $0.isEnabled }
    }
}
