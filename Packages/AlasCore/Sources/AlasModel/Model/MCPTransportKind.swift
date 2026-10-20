import CryptoKit
import Foundation

public enum MCPTransportKind: String, Codable, Equatable, Sendable {
    case stdio
    case http
    case sse
}
