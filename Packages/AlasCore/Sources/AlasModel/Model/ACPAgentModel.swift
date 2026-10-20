import Foundation
import AlasFoundation

public struct ACPAgentModel: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
