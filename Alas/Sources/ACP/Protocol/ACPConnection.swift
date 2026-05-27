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
        _ = try await client.send(ACPRequest(method: "session/cancel",
                                             params: ACPSessionCancelParams(sessionId: sessionId)))
    }

    func setMode(sessionId: String, modeId: String) async throws {
        _ = try await client.send(ACPRequest(method: "session/setMode",
                                             params: ACPSessionSetModeParams(sessionId: sessionId, modeId: modeId)))
    }

    func setModel(sessionId: String, modelId: String) async throws {
        _ = try await client.send(ACPRequest(method: "session/setModel",
                                             params: ACPSessionSetModelParams(sessionId: sessionId, modelId: modelId)))
    }

    func prompt(sessionId: String, blocks: [ACPContentBlock]) async throws {
        _ = try await client.send(ACPRequest(method: "session/prompt",
                                             params: ACPSessionPromptParams(sessionId: sessionId, prompt: blocks)))
    }

    func shutdown() async { await client.shutdown() }
}
