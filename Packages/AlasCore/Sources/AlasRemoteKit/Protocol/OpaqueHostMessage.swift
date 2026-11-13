import Foundation

/// A host channel message a client carries without knowing its shape: any
/// JSON value, kept as sorted-keys JSON and re-encoded unchanged.
public struct OpaqueHostMessage: Codable, Equatable, Sendable {
    public let json: Data

    public init(json: Data) {
        self.json = json
    }

    public init(from decoder: Decoder) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        json = try encoder.encode(AnyCodable(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try JSONDecoder().decode(AnyCodable.self, from: json).encode(to: encoder)
    }
}
