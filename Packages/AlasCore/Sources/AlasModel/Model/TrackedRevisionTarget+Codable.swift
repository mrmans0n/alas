import Foundation
import AlasFoundation

extension TrackedRevisionTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case expression
        case stackEntry = "stack-entry"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        switch kind {
        case .expression: self = .expression(value)
        case .stackEntry: self = .stackEntry(ggID: value)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .expression(let expression):
            try container.encode(Kind.expression, forKey: .kind)
            try container.encode(expression, forKey: .value)
        case .stackEntry(let ggID):
            try container.encode(Kind.stackEntry, forKey: .kind)
            try container.encode(ggID, forKey: .value)
        }
    }
}
