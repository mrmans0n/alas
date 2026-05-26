import Foundation

enum AgentAutoLaunch {
    struct Resolved: Equatable {
        let argv: [String]
        let agentId: String
    }

    /// Compute what (if anything) to launch in a freshly-created worktree's
    /// terminal. Pure — call sites pass in everything needed. Returns nil
    /// when no agent should be launched (mode = disabled, no agent picked,
    /// or the picked agent isn't enabled+installed in the registry).
    static func resolve(
        registry: AgentRegistry,
        globalAgentId: String?,
        globalUseBypass: Bool,
        projectMode: ProjectStartupScriptMode,
        projectAgentId: String?,
        projectUseBypass: Bool
    ) -> Resolved? {
        let agentId: String?
        let useBypass: Bool
        switch projectMode {
        case .disabled:
            return nil
        case .useGlobal:
            agentId = globalAgentId
            useBypass = globalUseBypass
        case .overrideGlobal, .appendToGlobal:
            // Agent override has no "append" semantics; we treat them the same.
            agentId = projectAgentId
            useBypass = projectUseBypass
        }
        guard let id = agentId else {
            return nil
        }
        guard let resolved = resolveExplicit(
            agentId: id,
            registry: registry,
            useBypass: useBypass
        ) else {
            return nil
        }
        return resolved
    }

    /// Resolve an explicit per-creation agent launch (e.g. chosen in the
    /// NewWorktreeDialog). Unlike `resolve`, this does not require a default
    /// agent to be configured.
    static func resolveExplicit(
        agentId: String,
        registry: AgentRegistry,
        useBypass: Bool
    ) -> Resolved? {
        guard let agent = registry.enabled().first(where: { $0.id == agentId }) else {
            return nil
        }
        return Resolved(
            argv: buildCommand(agent: agent, useBypass: useBypass),
            agentId: agent.id
        )
    }

    static func buildCommand(agent: AgentDefinition, useBypass: Bool) -> [String] {
        var argv: [String] = [agent.resolvedBinary]
        if let extra = agent.extraTerminalArgs, !extra.isEmpty {
            argv.append(contentsOf: extra)
        }
        if useBypass, let flag = agent.bypassPermissionsFlag {
            argv.append(flag)
        }
        return argv
    }
}
