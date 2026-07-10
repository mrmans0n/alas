import Foundation

struct ACPElicitationCapabilities: Codable, Equatable {
    let form: EmptyObject?
    let url: EmptyObject?

    static let full = ACPElicitationCapabilities(form: .init(), url: .init())
}

struct ACPElicitationRequest: Equatable {
    let id: JSONRPCID
    let params: ACPElicitationRequestParams
}

struct ACPElicitationRequestParams: Codable, Equatable {
    let sessionId: String?
    let requestId: JSONRPCID?
    let toolCallId: String?
    let mode: String
    let message: String
    let requestedSchema: ACPElicitationSchema?
    let elicitationId: String?
    let url: String?
    let meta: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case sessionId, requestId, toolCallId, mode, message
        case requestedSchema, elicitationId, url
        case meta = "_meta"
    }

    init(from decoder: Decoder) throws {
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

    var hasExactlyOneScope: Bool {
        (sessionId != nil) != (requestId != nil)
    }
}

struct ACPElicitationSchema: Codable, Equatable {
    let type: String?
    let title: String?
    let description: String?
    let properties: [String: ACPElicitationPropertySchema]
    let required: [String]?
    private(set) var propertiesAreValid = true

    init(
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

    enum CodingKeys: String, CodingKey {
        case type, title, description, properties, required
    }

    init(from decoder: Decoder) throws {
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

struct ACPElicitationPropertySchema: Codable, Equatable {
    let type: String
    let title: String?
    let description: String?
    let minLength: Int?
    let maxLength: Int?
    let pattern: String?
    let format: String?
    let minimum: Double?
    let maximum: Double?
    let minItems: Int?
    let maxItems: Int?
    let values: [String]?
    let oneOf: [ACPElicitationOption]?
    let items: ACPElicitationItemsSchema?
    let defaultValue: AnyCodable?
    let raw: AnyCodable

    enum CodingKeys: String, CodingKey {
        case type, title, description, minLength, maxLength, pattern, format
        case minimum, maximum, minItems, maxItems, oneOf, items
        case values = "enum"
        case defaultValue = "default"
    }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }
}

struct ACPElicitationItemsSchema: Codable, Equatable {
    let type: String?
    let values: [String]?
    let anyOf: [ACPElicitationOption]?

    enum CodingKeys: String, CodingKey {
        case type, anyOf
        case values = "enum"
    }
}

struct ACPElicitationOption: Codable, Equatable, Identifiable {
    let const: String
    let title: String?
    let description: String?

    var id: String { const }
}

enum ACPElicitationValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case strings([String])

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

struct ACPElicitationResponse: Codable, Equatable {
    let action: String
    let content: [String: ACPElicitationValue]?
    let meta: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case action, content
        case meta = "_meta"
    }

    static func accept(_ content: [String: ACPElicitationValue]? = nil) -> Self {
        .init(action: "accept", content: content, meta: nil)
    }

    static let decline = ACPElicitationResponse(action: "decline", content: nil, meta: nil)
    static let cancel = ACPElicitationResponse(action: "cancel", content: nil, meta: nil)
}

struct ACPElicitationCompleteParams: Codable, Equatable {
    let elicitationId: String
}
