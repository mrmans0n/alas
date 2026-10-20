import CryptoKit
import Foundation

public struct MCPAttachmentServerStatus: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let transport: MCPTransportKind
    public let disposition: MCPAttachmentDisposition

    public init(
        id: String,
        name: String,
        transport: MCPTransportKind,
        disposition: MCPAttachmentDisposition
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.disposition = disposition
    }
}
