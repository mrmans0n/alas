import Foundation

enum AdapterUpdateState: Equatable, Codable {
    case upToDate
    case available(current: String, latest: String)
    case unknown

    enum CodingKeys: String, CodingKey { case kind, current, latest }
    private enum Kind: String, Codable { case upToDate, available, unknown }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .upToDate:
            try c.encode(Kind.upToDate, forKey: .kind)
        case .unknown:
            try c.encode(Kind.unknown, forKey: .kind)
        case .available(let current, let latest):
            try c.encode(Kind.available, forKey: .kind)
            try c.encode(current, forKey: .current)
            try c.encode(latest, forKey: .latest)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .upToDate: self = .upToDate
        case .unknown:  self = .unknown
        case .available:
            self = .available(
                current: try c.decode(String.self, forKey: .current),
                latest:  try c.decode(String.self, forKey: .latest))
        }
    }
}
