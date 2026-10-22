import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

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

    /// The hooks new ACP sessions of `agentID` start with, as normalized JSON,
    /// or nil. Text that does not validate (a hand-edited config) is captured
    /// as written, so the session's attach reports the problem instead of
    /// starting without the hooks.
    public func sessionHooks(for agentID: String) -> String? {
        guard ACPClaudeSessionHooksPolicy.isConfigurable(agentID: agentID),
              let text = builtinState[agentID]?.sessionHooks?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        do {
            return try ACPClaudeSessionHooksPolicy.normalized(text)
        } catch {
            return text
        }
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
