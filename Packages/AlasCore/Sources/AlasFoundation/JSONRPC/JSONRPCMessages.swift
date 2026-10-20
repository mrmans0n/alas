import CoreFoundation
import Foundation

/// A generic JSON-RPC 2.0 envelope. Shared by every ACP wire type.
public struct JSONRPCEnvelope<Payload: Codable>: Codable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let method: String?
    public let params: Payload?
    public let result: Payload?
    public let error: JSONRPCError?

    public init(id: JSONRPCID?, method: String, params: Payload?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
        self.result = nil
        self.error = nil
    }
}

public enum JSONRPCID: Codable, Equatable, Hashable, Sendable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .number(n)
        return }
        self = .string(try c.decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
}

public struct JSONRPCError: Codable, Equatable, Error, Sendable {
    public let code: Int
    public let message: String
    public let data: AnyCodable?

    public init(code: Int, message: String, data: AnyCodable?) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Type-erased Codable used for `JSONRPCError.data` and `_meta` fields.
/// It only carries values that are JSON-compatible and safe to move across
/// actor boundaries as immutable payload data.
public struct AnyCodable: Codable, Equatable, Hashable, @unchecked Sendable {
    public let value: Any
    public init(_ value: Any) { self.value = value }

    private enum CanonicalValue: Equatable, Hashable, Encodable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([CanonicalValue])
        case object([CanonicalObjectMember])

        func encode(to encoder: Encoder) throws {
            switch self {
            case .null:
                var c = encoder.singleValueContainer()
                try c.encodeNil()
            case .bool(let value):
                var c = encoder.singleValueContainer()
                try c.encode(value)
            case .int(let value):
                var c = encoder.singleValueContainer()
                try c.encode(value)
            case .double(let value):
                var c = encoder.singleValueContainer()
                try c.encode(value)
            case .string(let value):
                var c = encoder.singleValueContainer()
                try c.encode(value)
            case .array(let values):
                var c = encoder.unkeyedContainer()
                for value in values { try c.encode(value) }
            case .object(let members):
                var c = encoder.container(keyedBy: CanonicalObjectCodingKey.self)
                for member in members {
                    try c.encode(member.value, forKey: .init(member.key))
                }
            }
        }
    }

    private struct CanonicalObjectCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    private struct CanonicalObjectMember: Equatable, Hashable {
        let key: String
        let value: CanonicalValue

        public init(key: String, value: CanonicalValue) {
            self.key = key
            self.value = value
        }
    }

    private var canonicalValue: CanonicalValue {
        return AnyCodable.canonicalize(value)
    }

    private static func canonicalize(_ value: Any) -> CanonicalValue {
        if let value = value as? AnyCodable { return value.canonicalValue }
        if value is NSNull { return .null }
        if let value = value as? NSNumber {
            let cfValue = value as CFNumber
            if CFGetTypeID(cfValue) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            if CFNumberIsFloatType(cfValue) {
                return .double(value.doubleValue)
            }
            return .int(value.intValue)
        }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? Int { return .int(value) }
        if let value = value as? Double { return .double(value) }
        if let value = value as? String { return .string(value) }
        if let value = value as? [AnyCodable] {
            return .array(value.map { $0.canonicalValue })
        }
        if let value = value as? [String: AnyCodable] {
            return .object(value
                .sorted(by: { $0.key < $1.key })
                .map { key, value in
                    CanonicalObjectMember(key: key, value: value.canonicalValue)
                })
        }
        if let value = value as? [Any] {
            return .array(value.map { AnyCodable.canonicalize($0) })
        }
        if let value = value as? NSArray {
            return .array(value.map { AnyCodable.canonicalize($0) })
        }
        if let value = value as? [String: Any] {
            return .object(value
                .sorted(by: { $0.key < $1.key })
                .map { key, value in
                    CanonicalObjectMember(key: key, value: AnyCodable.canonicalize(value))
                })
        }
        if let value = value as? NSDictionary {
            var members: [CanonicalObjectMember] = []
            for (rawKey, rawValue) in value {
                guard let key = rawKey as? String else { return .null }
                members.append(CanonicalObjectMember(key: key, value: canonicalize(rawValue)))
            }
            return .object(members.sorted(by: { $0.key < $1.key }))
        }
        return .null
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull()
        return }
        if let v = try? c.decode(Bool.self) { self.value = v
        return }
        if let v = try? c.decode(Int.self) { self.value = v
        return }
        if let v = try? c.decode(Double.self) { self.value = v
        return }
        if let v = try? c.decode(String.self) { self.value = v
        return }
        if let v = try? c.decode([AnyCodable].self) { self.value = v
        return }
        if let v = try? c.decode([String: AnyCodable].self) { self.value = v
        return }
        self.value = NSNull()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(canonicalValue)
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        lhs.canonicalValue == rhs.canonicalValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalValue)
    }
}
