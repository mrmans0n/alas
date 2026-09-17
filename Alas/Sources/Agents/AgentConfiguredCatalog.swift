enum AgentConfiguredCatalog {
    static func all(
        builtinState: [String: BuiltinAgentState],
        customs: [AgentDefinition]
    ) -> [AgentDefinition] {
        let builtins = AgentBuiltins.catalog.map { catalogAgent in
            var agent = catalogAgent
            if let state = builtinState[agent.id] {
                agent.isEnabled = state.isEnabled
                agent.binaryOverride = state.binaryOverride
                agent.extraTerminalArgs = state.extraTerminalArgs
            }
            return agent
        }
        return builtins + customs
    }

    static func enabled(
        builtinState: [String: BuiltinAgentState],
        customs: [AgentDefinition]
    ) -> [AgentDefinition] {
        all(builtinState: builtinState, customs: customs).filter(\.isEnabled)
    }
}
