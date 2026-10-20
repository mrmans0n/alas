import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

public enum LSPPrepareRenameResult: Decodable, Equatable, Sendable {
    case range(LSPRange, placeholder: String?)
    case defaultBehavior(Bool)

    private enum CodingKeys: String, CodingKey { case range, placeholder, defaultBehavior }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Bool.self, forKey: .defaultBehavior) {
            self = .defaultBehavior(value)
        } else if let range = try container.decodeIfPresent(LSPRange.self, forKey: .range) {
            self = .range(range, placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder))
        } else {
            self = try .range(LSPRange(from: decoder), placeholder: nil)
        }
    }
}
