enum MCPServerRegistration: Equatable {
    case unknown
    case registered
    case notRegistered
}

/// What Alas has seen from a session's built-in MCP server on this attach.
enum MCPRegistrationEvidence: Equatable {
    case none
    /// A `cli` socket request carrying the session's id. The socket can't tell
    /// the MCP server's requests from the agent's shell running `alas`, so
    /// this proves the server only when no fresh hello can be expected.
    case request
    /// The server's one-shot `mcp_hello`, sent when it starts.
    case hello
}

/// Pure policy for resolving registration from observable signals so the
/// timing wiring in the session manager stays thin and this stays testable.
enum MCPRegistrationDecision {
    /// - Parameter reattachedToRunningServer: the attach adopted an agent
    ///   process that was already running with a stdio server (e.g. one that
    ///   survived an app restart in its broker). That server said hello to the
    ///   previous attach, so no hello will come; without evidence the state
    ///   stays `.unknown` rather than claiming the server never started.
    static func resolve(
        evidence: MCPRegistrationEvidence,
        graceElapsed: Bool,
        reattachedToRunningServer: Bool
    ) -> MCPServerRegistration {
        switch evidence {
        case .hello:
            return .registered
        case .request where reattachedToRunningServer:
            return .registered
        case .none, .request:
            if reattachedToRunningServer { return .unknown }
            return graceElapsed ? .notRegistered : .unknown
        }
    }
}
