import Foundation

/// Tracks which sessions' built-in MCP server actually announced itself
/// (see `MCPHelloEvent`). Cleared per attach epoch so a reconnect re-proves
/// registration. Main-actor: mutated from the socket callback and read from
/// the session manager, both on the main queue.
@MainActor
final class MCPRegistrationRegistry {
    struct Record: Equatable {
        let transport: MCPTransportKind
    }
    private var records: [String: Record] = [:]

    func recordHello(sessionId: String, transport: MCPTransportKind) {
        records[sessionId] = Record(transport: transport)
    }
    func clear(sessionId: String) { records[sessionId] = nil }
    func isRegistered(sessionId: String) -> Bool { records[sessionId] != nil }
    func transport(sessionId: String) -> MCPTransportKind? { records[sessionId]?.transport }
}
