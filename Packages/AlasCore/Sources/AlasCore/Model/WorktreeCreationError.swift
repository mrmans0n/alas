import Foundation
import os

/// A headless creation that failed; its row keeps the failure for retry.
public struct WorktreeCreationError: Codable, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}
