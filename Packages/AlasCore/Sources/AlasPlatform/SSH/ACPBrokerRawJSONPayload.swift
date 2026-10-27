import Foundation

/// Opaque source bytes for a future broker transport boundary. Decoding this
/// wrapper does not validate its contents as JSON or acknowledge consumption.
public struct ACPBrokerRawJSONPayload: Codable, Equatable, Sendable {
    public let bytes: Data
    private static let format = "alas.acp.raw-json.v1"

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let format = try container.decode(String.self)
        guard format == Self.format else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported raw broker payload format")
        }
        let encoded = try container.decode(String.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected exactly two raw broker payload elements")
        }
        guard let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected canonical padded base64")
        }
        self.bytes = bytes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(Self.format)
        try container.encode(bytes.base64EncodedString())
    }
}
