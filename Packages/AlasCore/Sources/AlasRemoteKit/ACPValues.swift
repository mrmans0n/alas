import Foundation

public enum ACPConfigValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case boolean(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self = .boolean(b)
            return
        }
        self = .string(try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try c.encode(value)
        case .boolean(let value):
            try c.encode(value)
        }
    }
}

public enum ACPElicitationValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case strings([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? c.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else {
            self = .strings(try c.decode([String].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .integer(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .boolean(let value): try c.encode(value)
        case .strings(let value): try c.encode(value)
        }
    }
}
