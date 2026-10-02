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
    /// How long a fresh server gets to say hello before the row warns. Past
    /// Claude Code's default 30s MCP connect timeout, so a harness that is
    /// merely slow to connect (many servers, a long restore) lands its hello
    /// before the warning instead of flashing it.
    static let helloGrace: Duration = .seconds(35)

    /// Whether an attach keeps a built-in server the adopted agent is already
    /// connected to, so it won't send a new hello. Only a broker-adopted agent
    /// keeps its connections.
    /// - stdio: the server lives under the agent. A hello recorded over
    ///   another transport earlier in this app run means the previous attach
    ///   used a different server, so this stdio one is new and must say hello.
    /// - HTTP: the app's supervisor keeps the process (same URL and token)
    ///   across attaches within an app run, so the adapter sees an unchanged
    ///   session and keeps its connection without a new `initialize`. An HTTP
    ///   hello recorded in this app run proves that server; without one (e.g.
    ///   after an app restart, which respawns it on a new port) the adapter
    ///   reconnects and the server says hello again.
    /// A previous attach in this app run that already found no server (a
    /// reconnect after the warning) has nothing that could have survived, so
    /// it keeps the fresh-launch rules and the warning.
    static func reattachesRunningServer(
        builtInTransport: MCPTransportKind?,
        adoptedRunningAgent: Bool,
        recordedHelloTransport: MCPTransportKind?,
        previousAttachFoundNoServer: Bool = false
    ) -> Bool {
        guard adoptedRunningAgent, !previousAttachFoundNoServer else { return false }
        switch builtInTransport {
        case .stdio:
            return recordedHelloTransport == nil || recordedHelloTransport == .stdio
        case .http:
            return recordedHelloTransport == .http
        case .sse, nil:
            return false
        }
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
