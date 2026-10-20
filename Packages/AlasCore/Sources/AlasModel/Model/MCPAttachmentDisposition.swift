import CryptoKit
import Foundation
import AlasFoundation

public enum MCPAttachmentDisposition: Equatable, Sendable {
    case requested
    case skipped(MCPAttachmentSkipReason)
}
