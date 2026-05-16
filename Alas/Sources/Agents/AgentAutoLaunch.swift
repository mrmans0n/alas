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
        guard let id = agentId,
              let agent = registry.enabled().first(where: { $0.id == id }) else {
            return nil
        }
        var argv: [String] = [agent.resolvedBinary]
        if useBypass, let flag = agent.bypassPermissionsFlag {
            argv.append(flag)
        }
        return Resolved(argv: argv, agentId: agent.id)
    }
}
