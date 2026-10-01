import Foundation

/// Tracks which sessions' built-in MCP server actually announced itself
/// (see `MCPHelloEvent`). Cleared per attach epoch so a reconnect re-proves
/// registration. Main-actor: mutated from the socket callback and read from
/// the session manager, both on the main queue.
@MainActor
final class MCPRegistrationRegistry {
    struct Record: Equatable {
        let transport: MCPTransportKind
        /// Increases with every hello, so an attach can tell a hello that
        /// arrived after it started from one an earlier server sent.
        let sequence: Int
    }
    private var records: [String: Record] = [:]
    private var nextSequence = 0

    func recordHello(sessionId: String, transport: MCPTransportKind) {
        nextSequence += 1
        records[sessionId] = Record(transport: transport, sequence: nextSequence)
    }
    func clear(sessionId: String) { records[sessionId] = nil }
    func isRegistered(sessionId: String) -> Bool { records[sessionId] != nil }
    func record(sessionId: String) -> Record? { records[sessionId] }
}
