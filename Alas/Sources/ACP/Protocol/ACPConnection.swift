import Foundation

struct ACPInitializeOutcome: Equatable {
    let promptCapabilities: ACPInitializeResult.ACPPromptCapabilities
    let authMethods: [ACPInitializeResult.ACPAuthMethod]
    let loadSession: Bool
    let sessionCapabilities: ACPInitializeResult.ACPAgentSessionCapabilities
    let mcpCapabilities: ACPMCPServerCapabilities
}

/// Higher-level wrapper that owns one `ACPClient` and exposes typed
/// methods for the messages we send.
final class ACPConnection: @unchecked Sendable {
    let client: ACPClient

    init(client: ACPClient) { self.client = client }

    /// Returns the initialize outcome advertised by the agent, defaulting
    /// missing prompt capability fields to false and missing auth methods to empty.
    @discardableResult
    func initialize() async throws -> ACPInitializeOutcome {
        let req = ACPRequest(method: "initialize",
                             params: ACPInitializeParams(
                                protocolVersion: ACPProtocolVersion.current,
                                clientCapabilities: .init(
                                    fs: .init(readTextFile: true, writeTextFile: true),
                                    terminal: true)))
        let resp = try await client.send(req)
        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: resp.body)
        return ACPInitializeOutcome(
            promptCapabilities: result.agentCapabilities?.promptCapabilities ?? .init(),
            authMethods: result.authMethods,
            loadSession: result.agentCapabilities?.loadSession ?? false,
            sessionCapabilities: result.agentCapabilities?.sessionCapabilities ?? .init(),
            mcpCapabilities: result.agentCapabilities?.mcpCapabilities ?? .init()
        )
    }

    func newSession(cwd: String) async throws -> ACPSessionNewResult {
        let req = ACPRequest(method: "session/new",
                             params: ACPSessionNewParams(cwd: cwd, mcpServers: []))
        let resp = try await client.send(req)
        let result = try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
        guard !result.sessionId.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "session/new response is missing sessionId"
            ))
        }
        return result
    }

    func authenticate(methodId: String) async throws {
        _ = try await client.send(ACPRequest(
            method: "authenticate",
            params: ACPAuthenticateParams(methodId: methodId)
        ))
    }

    func loadSession(cwd: String, sessionId: String) async throws -> ACPSessionNewResult {
        let req = ACPRequest(method: "session/load",
                             params: ACPSessionLoadParams(cwd: cwd, sessionId: sessionId, mcpServers: []))
        let resp = try await client.send(req)
        let result = try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
        return result.sessionId.isEmpty ? result.withSessionId(sessionId) : result
    }

    func resumeSession(cwd: String, sessionId: String) async throws -> ACPSessionNewResult {
        let req = ACPRequest(
            method: "session/resume",
            params: ACPSessionResumeParams(cwd: cwd, sessionId: sessionId, mcpServers: [])
        )
        let resp = try await client.send(req)
        let result = try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
        return result.sessionId.isEmpty ? result.withSessionId(sessionId) : result
    }

    func listSessions(cwd: String?, cursor: String? = nil) async throws -> ACPSessionListResult {
        let req = ACPRequest(
            method: "session/list",
            params: ACPSessionListParams(cwd: cwd, cursor: cursor)
        )
        let resp = try await client.send(req)
        return try JSONDecoder().decode(ACPSessionListResult.self, from: resp.body)
    }

    func forkSession(cwd: String, sessionId: String) async throws -> ACPSessionNewResult {
        let req = ACPRequest(
            method: "session/fork",
            params: ACPSessionForkParams(cwd: cwd, sessionId: sessionId, mcpServers: [])
        )
        let resp = try await client.send(req)
        return try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
    }

    func cancel(sessionId: String) async throws {
        // ACP defines `session/cancel` as a JSON-RPC NOTIFICATION
        // (no `id`, no reply). Sending it as a request and awaiting a
        // response left `userCancel()` suspended forever against
        // spec-compliant agents, so the UI never returned to idle.
        try await client.notify(ACPRequest(method: "session/cancel",
                                           params: ACPSessionCancelParams(sessionId: sessionId)))
    }

    // ACP wire methods use snake_case (`session/set_mode`,
    // `session/set_model`). Cursor / Kiro / claude-agent-acp all
    // method-not-found camelCase variants, which previously left Alas
    // showing the new selection while the agent stayed on the old one.
    func setMode(sessionId: String, modeId: String) async throws {
        _ = try await client.send(ACPRequest(method: "session/set_mode",
                                             params: ACPSessionSetModeParams(sessionId: sessionId, modeId: modeId)))
    }

    func setModel(sessionId: String, modelId: String) async throws {
        _ = try await client.send(ACPRequest(method: "session/set_model",
                                             params: ACPSessionSetModelParams(sessionId: sessionId, modelId: modelId)))
    }

    /// Sends a config-option change and returns the agent's refreshed
    /// `configOptions` list. The agent may return empty (older/non-compliant
    /// implementations) in which case the caller's optimistic local update
    /// stands; on a full echo the caller should overwrite local state so
    /// dependent options stay in sync.
    func setConfigOption(sessionId: String,
                         configId: String,
                         value: ACPConfigValue) async throws -> [ACPConfigOption] {
        let resp = try await client.send(ACPRequest(method: "session/set_config_option",
                                                    params: ACPSessionSetConfigOptionParams(
                                                        sessionId: sessionId,
                                                        configId: configId,
                                                        value: value)))
        let result = try? JSONDecoder().decode(ACPSessionSetConfigOptionResult.self, from: resp.body)
        return result?.configOptions ?? []
    }

    func prompt(sessionId: String, blocks: [ACPContentBlock]) async throws {
        _ = try await client.send(ACPRequest(method: "session/prompt",
                                             params: ACPSessionPromptParams(sessionId: sessionId, prompt: blocks)))
    }

    func shutdown() async { await client.shutdown() }
}
