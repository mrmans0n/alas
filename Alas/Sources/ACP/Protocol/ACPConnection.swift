import Foundation

/// Higher-level wrapper that owns one `ACPClient` and exposes typed
/// methods for the messages we send.
final class ACPConnection: @unchecked Sendable {
    let client: ACPClient

    init(client: ACPClient) { self.client = client }

    func initialize() async throws {
        let req = ACPRequest(method: "initialize",
                             params: ACPInitializeParams(
                                protocolVersion: ACPProtocolVersion.current,
                                clientCapabilities: .init(fs: .init(readTextFile: true, writeTextFile: true))))
        _ = try await client.send(req)
    }

    func newSession(cwd: String) async throws -> ACPSessionNewResult {
        let req = ACPRequest(method: "session/new",
                             params: ACPSessionNewParams(cwd: cwd, mcpServers: []))
        let resp = try await client.send(req)
        return try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
    }

    func loadSession(cwd: String, sessionId: String) async throws -> ACPSessionNewResult {
        let req = ACPRequest(method: "session/load",
                             params: ACPSessionLoadParams(cwd: cwd, sessionId: sessionId, mcpServers: []))
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

    func prompt(sessionId: String, blocks: [ACPContentBlock]) async throws {
        _ = try await client.send(ACPRequest(method: "session/prompt",
                                             params: ACPSessionPromptParams(sessionId: sessionId, prompt: blocks)))
    }

    func shutdown() async { await client.shutdown() }
}
