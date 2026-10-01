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
    /// Whether an attach keeps a stdio built-in server that was already
    /// running, so it won't send a new hello. Only a broker-adopted agent
    /// keeps its servers, and only a stdio server lives under the agent; an
    /// HTTP one is respawned by the app on each attach. A hello recorded over
    /// another transport earlier in this app run means the previous attach
    /// used a different server, so this stdio one is new and must say hello.
    static func reattachesRunningServer(
        builtInTransport: MCPTransportKind?,
        adoptedRunningAgent: Bool,
        recordedHelloTransport: MCPTransportKind?
    ) -> Bool {
        guard builtInTransport == .stdio, adoptedRunningAgent else { return false }
        return recordedHelloTransport == nil || recordedHelloTransport == .stdio
    }

    /// Whether the recorded hello counts for this attach: any hello does,
    /// except the one a superseded server sent before the attach started.
    static func isCurrentHello(_ sequence: Int?, staleSequence: Int?) -> Bool {
        guard let sequence else { return false }
        return sequence != staleSequence
    }

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
