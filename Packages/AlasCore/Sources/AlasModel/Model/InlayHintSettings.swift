import Foundation
import AlasFoundation

public struct InlayHintSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var parameters = true
    public var types = true

    public init(enabled: Bool = true, parameters: Bool = true, types: Bool = true) {
        self.enabled = enabled
        self.parameters = parameters
        self.types = types
    }

    private enum CodingKeys: String, CodingKey { case enabled, parameters, types }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        parameters = try c.decodeIfPresent(Bool.self, forKey: .parameters) ?? true
        types = try c.decodeIfPresent(Bool.self, forKey: .types) ?? true
    }
}
