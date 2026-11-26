import Crypto
import Foundation
import AlasFoundation

public enum MCPTransportKind: String, Codable, Equatable, Sendable {
    case stdio
    case http
    case sse
    /// Answered by the client over the ACP connection (MCP-over-ACP).
    case acp
}
