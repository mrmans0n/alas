import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Tracks which sessions' built-in MCP server actually announced itself
/// (see `MCPHelloEvent`). Cleared per attach epoch so a reconnect re-proves
/// registration. Main-actor: mutated from the socket callback and read from
/// the session manager, both on the main queue.
@MainActor
public final class MCPRegistrationRegistry {
    public struct Record: Equatable, Sendable {
        public let transport: MCPTransportKind
        /// Increases with every hello, so an attach can tell a hello that
        /// arrived after it started from one an earlier server sent.
        public let sequence: Int

        public init(transport: MCPTransportKind, sequence: Int) {
            self.transport = transport
            self.sequence = sequence
        }
    }
    private var records: [String: Record] = [:]
    private var nextSequence = 0

    public func recordHello(sessionId: String, transport: MCPTransportKind) {
        nextSequence += 1
        records[sessionId] = Record(transport: transport, sequence: nextSequence)
    }
    public func clear(sessionId: String) { records[sessionId] = nil }
    public func isRegistered(sessionId: String) -> Bool { records[sessionId] != nil }
    public func record(sessionId: String) -> Record? { records[sessionId] }

    public init() {}
}
