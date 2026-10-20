import CryptoKit
import Foundation
import AlasFoundation

public enum MCPTransportKind: String, Codable, Equatable, Sendable {
    case stdio
    case http
    case sse
}
