import Foundation

/// The one-shot registration ping sent by `alas mcp` (see alas-client
/// `send_hello`). Its own socket `kind`, distinct from `AlasCLIRequest`
/// (`kind == "cli"`) and `AgentHookEvent` (no `kind`).
struct MCPHelloEvent: Equatable {
    let sessionId: String
    let transport: MCPTransportKind

    enum DecodeError: Error { case malformed }

    static func decode(from data: Data) throws -> MCPHelloEvent {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["kind"] as? String) == "mcp_hello",
              let sessionId = json["session_id"] as? String,
              !sessionId.isEmpty else {
            throw DecodeError.malformed
        }
        let raw = (json["transport"] as? String) ?? "stdio"
        let transport: MCPTransportKind = (raw == "http") ? .http : .stdio
        return MCPHelloEvent(sessionId: sessionId, transport: transport)
    }
}
