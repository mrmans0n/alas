import Foundation

public enum ACPBrokerWireContext: Equatable, Sendable, Codable {
    case legacyV1
    case rawV2

    private enum CodingKeys: String, CodingKey { case acpVersion, payloadFormat }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .acpVersion)
        let format = try container.decode(String.self, forKey: .payloadFormat)
        switch (version, format) {
        case (1, "structured"): self = .legacyV1
        case (2, "alas.acp.raw-json.v1"): self = .rawV2
        default:
            throw DecodingError.dataCorruptedError(forKey: .payloadFormat, in: container,
                debugDescription: "Unsupported ACP broker wire context")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self == .legacyV1 ? 1 : 2, forKey: .acpVersion)
        try container.encode(self == .legacyV1 ? "structured" : "alas.acp.raw-json.v1", forKey: .payloadFormat)
    }
}
