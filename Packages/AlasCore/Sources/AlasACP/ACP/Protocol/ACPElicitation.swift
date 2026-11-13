import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

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

    /// codex-acp marks questions that never block its turn with
    /// `_meta.codex.delivery == "async"`. Only forms can be optional.
    public var isAsyncDelivery: Bool {
        guard mode == "form",
              let root = meta?.value as? [String: AnyCodable],
              let codex = root["codex"]?.value as? [String: AnyCodable],
              let delivery = codex["delivery"]?.value as? String
        else { return false }
        return delivery == "async"
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

    /// The `_meta.codex` object codex-acp attaches to each property. `raw`
    /// already captures the full per-property JSON, so no dedicated CodingKey
    /// is needed.
    private var codexMeta: [String: AnyCodable]? {
        guard let root = raw.value as? [String: AnyCodable],
              let meta = root["_meta"]?.value as? [String: AnyCodable]
        else { return nil }
        return meta["codex"]?.value as? [String: AnyCodable]
    }

    /// codex-acp >= 1.12 (#299) marks `request_user_input` fields that
    /// should be masked with `_meta.codex.isSecret`.
    public var isSecret: Bool {
        codexMeta?["isSecret"]?.value as? Bool ?? false
    }

    /// `_meta.codex.isOther` sits on the question property (not on its
    /// "None of the above" option) and means the user may type an own answer.
    public var acceptsOwnAnswer: Bool {
        codexMeta?["isOther"]?.value as? Bool ?? false
    }

    /// The question a free-text field belongs to, from the negotiated
    /// `_meta.questionCustomAnswer`, else the legacy `_meta.codex.questionId`.
    /// Note ids can gain a numeric suffix on collision, so never derive this
    /// from the field key or its label. A marker that isn't version 1 on a
    /// plain string field leaves the field independent.
    public var noteQuestionId: String? {
        if type == "string", oneOf == nil, values == nil,
           let root = raw.value as? [String: AnyCodable],
           let meta = root["_meta"]?.value as? [String: AnyCodable],
           let marker = meta["questionCustomAnswer"]?.value as? [String: AnyCodable],
           marker["version"]?.value as? Int == 1,
           let question = marker["questionId"]?.value as? String, !question.isEmpty {
            return question
        }
        guard codexMeta?["role"]?.value as? String == "user_note" else { return nil }
        return codexMeta?["questionId"]?.value as? String
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
