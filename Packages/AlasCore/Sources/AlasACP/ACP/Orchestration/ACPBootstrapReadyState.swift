import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum ACPBootstrapReadyState: Equatable, Sendable {
    case ready
    case needsSetup(String)
    case needsAuthentication(String)
    case failed(String)
}

public struct ACPWorktreeSessionBootstrapError: LocalizedError, Sendable {
    public let message: String
    public var consumedInitialPrompt = false

    public var errorDescription: String? { message }

    public init(message: String, consumedInitialPrompt: Bool = false) {
        self.message = message
        self.consumedInitialPrompt = consumedInitialPrompt
    }
}
