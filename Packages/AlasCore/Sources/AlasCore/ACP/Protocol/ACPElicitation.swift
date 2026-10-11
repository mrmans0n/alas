import Foundation

public struct ACPElicitationCapabilities: Codable, Equatable, Sendable {
    public let form: EmptyObject?
    public let url: EmptyObject?

    public static let full = ACPElicitationCapabilities(form: .init(), url: .init())

    public init(form: EmptyObject?, url: EmptyObject?) {
        self.form = form
        self.url = url
    }
}

public struct ACPElicitationRequest: Equatable, Sendable {
    public let id: JSONRPCID
    public let params: ACPElicitationRequestParams

    public init(id: JSONRPCID, params: ACPElicitationRequestParams) {
        self.id = id
        self.params = params
    }
}

public struct ACPElicitationRequestParams: Codable, Equatable, Sendable {
    public let sessionId: String?
    public let requestId: JSONRPCID?
    public let toolCallId: String?
    public let mode: String
    public let message: String
    public let requestedSchema: ACPElicitationSchema?
    public let elicitationId: String?
    public let url: String?
    public let meta: AnyCodable?

    public enum CodingKeys: String, CodingKey, Sendable {
        case sessionId, requestId, toolCallId, mode, message
        case requestedSchema, elicitationId, url
        case meta = "_meta"
    }

    public init(
        sessionId: String? = nil,
        requestId: JSONRPCID? = nil,
        toolCallId: String? = nil,
        mode: String,
        message: String,
        requestedSchema: ACPElicitationSchema? = nil,
        elicitationId: String? = nil,
        url: String? = nil,
        meta: AnyCodable? = nil
    ) {
        self.sessionId = sessionId
        self.requestId = requestId
        self.toolCallId = toolCallId
        self.mode = mode
        self.message = message
        self.requestedSchema = requestedSchema
        self.elicitationId = elicitationId
        self.url = url
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        requestId = try c.decodeIfPresent(JSONRPCID.self, forKey: .requestId)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "form"
        message = try c.decode(String.self, forKey: .message)
        requestedSchema = try c.decodeIfPresent(ACPElicitationSchema.self, forKey: .requestedSchema)
        elicitationId = try c.decodeIfPresent(String.self, forKey: .elicitationId)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        meta = try c.decodeIfPresent(AnyCodable.self, forKey: .meta)
    }

    public var hasExactlyOneScope: Bool {
        (sessionId != nil) != (requestId != nil)
    }
}

public struct ACPElicitationSchema: Codable, Equatable, Sendable {
    public let type: String?
    public let title: String?
    public let description: String?
    public let properties: [String: ACPElicitationPropertySchema]
    public let required: [String]?
    public private(set) var propertiesAreValid = true

    public init(
        type: String? = "object",
        title: String? = nil,
        description: String? = nil,
        properties: [String: ACPElicitationPropertySchema],
        required: [String]? = nil
    ) {
        self.type = type
        self.title = title
        self.description = description
        self.properties = properties
        self.required = required
        propertiesAreValid = true
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case type, title, description, properties, required
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        do {
            properties = try c.decode([String: ACPElicitationPropertySchema].self, forKey: .properties)
            propertiesAreValid = true
        } catch {
            properties = [:]
            propertiesAreValid = false
        }
        required = try? c.decode([String].self, forKey: .required)
    }
}

public struct ACPElicitationPropertySchema: Codable, Equatable, Sendable {
    public let type: String
    public let title: String?
    public let description: String?
    public let minLength: Int?
    public let maxLength: Int?
    public let pattern: String?
    public let format: String?
    public let minimum: Double?
    public let maximum: Double?
    public let minItems: Int?
    public let maxItems: Int?
    public let values: [String]?
    public let oneOf: [ACPElicitationOption]?
    public let items: ACPElicitationItemsSchema?
    public let defaultValue: AnyCodable?
    public let raw: AnyCodable

    public enum CodingKeys: String, CodingKey, Sendable {
        case type, title, description, minLength, maxLength, pattern, format
        case minimum, maximum, minItems, maxItems, oneOf, items
        case values = "enum"
        case defaultValue = "default"
    }

    public init(from decoder: Decoder) throws {
        let raw = try AnyCodable(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? "unknown"
        title = try? c.decode(String.self, forKey: .title)
        description = try? c.decode(String.self, forKey: .description)
        minLength = try? c.decode(Int.self, forKey: .minLength)
        maxLength = try? c.decode(Int.self, forKey: .maxLength)
        pattern = try? c.decode(String.self, forKey: .pattern)
        format = try? c.decode(String.self, forKey: .format)
        minimum = try? c.decode(Double.self, forKey: .minimum)
        maximum = try? c.decode(Double.self, forKey: .maximum)
        minItems = try? c.decode(Int.self, forKey: .minItems)
        maxItems = try? c.decode(Int.self, forKey: .maxItems)
        values = try? c.decode([String].self, forKey: .values)
        oneOf = try? c.decode([ACPElicitationOption].self, forKey: .oneOf)
        items = try? c.decode(ACPElicitationItemsSchema.self, forKey: .items)
        defaultValue = try? c.decode(AnyCodable.self, forKey: .defaultValue)
        self.raw = raw
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }

    /// codex-acp >= 1.12 (#299) marks `request_user_input` fields that
    /// should be masked with `_meta.codex.isSecret`. `raw` already captures
    /// the full per-property JSON, so no dedicated CodingKey is needed.
    public var isSecret: Bool {
        guard let root = raw.value as? [String: AnyCodable],
              let meta = root["_meta"]?.value as? [String: AnyCodable],
              let codex = meta["codex"]?.value as? [String: AnyCodable],
              let flag = codex["isSecret"]?.value as? Bool
        else { return false }
        return flag
    }
}

public struct ACPElicitationItemsSchema: Codable, Equatable, Sendable {
    public let type: String?
    public let values: [String]?
    public let anyOf: [ACPElicitationOption]?

    public enum CodingKeys: String, CodingKey, Sendable {
        case type, anyOf
        case values = "enum"
    }

    public init(type: String?, values: [String]?, anyOf: [ACPElicitationOption]?) {
        self.type = type
        self.values = values
        self.anyOf = anyOf
    }
}

public struct ACPElicitationOption: Codable, Equatable, Identifiable, Sendable {
    public let const: String
    public let title: String?
    public let description: String?

    public var id: String { const }

    public init(const: String, title: String?, description: String?) {
        self.const = const
        self.title = title
        self.description = description
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

public struct ACPElicitationResponse: Codable, Equatable, Sendable {
    public let action: String
    public let content: [String: ACPElicitationValue]?
    public let meta: AnyCodable?

    public enum CodingKeys: String, CodingKey, Sendable {
        case action, content
        case meta = "_meta"
    }

    public static func accept(_ content: [String: ACPElicitationValue]? = nil) -> Self {
        .init(action: "accept", content: content, meta: nil)
    }

    public static let decline = ACPElicitationResponse(action: "decline", content: nil, meta: nil)
    public static let cancel = ACPElicitationResponse(action: "cancel", content: nil, meta: nil)

    public init(action: String, content: [String: ACPElicitationValue]?, meta: AnyCodable?) {
        self.action = action
        self.content = content
        self.meta = meta
    }
}

public struct ACPElicitationCompleteParams: Codable, Equatable, Sendable {
    public let elicitationId: String

    public init(elicitationId: String) {
        self.elicitationId = elicitationId
    }
}
