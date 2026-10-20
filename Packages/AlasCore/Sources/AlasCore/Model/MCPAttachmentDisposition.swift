import CryptoKit
import Foundation

public enum MCPAttachmentDisposition: Equatable, Sendable {
    case requested
    case skipped(MCPAttachmentSkipReason)
}
