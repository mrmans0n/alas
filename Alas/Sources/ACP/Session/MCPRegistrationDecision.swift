import OSLog

/// Built-in MCP registration timeline: attach, grace armed, proof received,
/// grace resolved. Filter with `log stream --predicate 'category == "mcp-registration"'`.
let mcpRegistrationLogger = Logger(subsystem: "io.nlopez.alas", category: "mcp-registration")

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
    /// A `cli` socket request the built-in server tagged as its own. It
    /// proves some server for this session is running, but not which one: an
    /// adopted agent that fell back to `session/new` may still run the server
    /// from its earlier session.
    case serverRequest
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
    /// - HTTP: when the app's supervisor reuses its running process (same URL
    ///   and token), the adapter sees an unchanged session and keeps its
    ///   connection without a new `initialize`, so the hello that process
    ///   sent earlier in this app run proves it. A respawned process (after a
    ///   failed attach or an app restart) has a new URL and token, so the
    ///   adapter reconnects and the new process must say hello.
    /// A previous attach in this app run that already found no server (a
    /// reconnect after the warning) has nothing that could have survived, so
    /// it keeps the fresh-launch rules and the warning.
    static func reattachesRunningServer(
        builtInTransport: MCPTransportKind?,
        adoptedRunningAgent: Bool,
        recordedHelloTransport: MCPTransportKind?,
        reusedHTTPServer: Bool = false,
        previousAttachFoundNoServer: Bool = false
    ) -> Bool {
        guard adoptedRunningAgent, !previousAttachFoundNoServer else { return false }
        switch builtInTransport {
        case .stdio:
            return recordedHelloTransport == nil || recordedHelloTransport == .stdio
        case .http:
            return reusedHTTPServer && recordedHelloTransport == .http
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
    /// - Parameter requiresFreshHello: an adopted agent fell back to
    ///   `session/new`, so only the new server's hello proves this attach;
    ///   its previous server's requests are indistinguishable from the new
    ///   one's.
    static func resolve(
        evidence: MCPRegistrationEvidence,
        graceElapsed: Bool,
        reattachedToRunningServer: Bool,
        requiresFreshHello: Bool = false
    ) -> MCPServerRegistration {
        switch evidence {
        case .hello:
            return .registered
        case .serverRequest where !requiresFreshHello:
            return .registered
        case .request where reattachedToRunningServer:
            return .registered
        case .none, .request, .serverRequest:
            if reattachedToRunningServer { return .unknown }
            return graceElapsed ? .notRegistered : .unknown
        }
    }
}
