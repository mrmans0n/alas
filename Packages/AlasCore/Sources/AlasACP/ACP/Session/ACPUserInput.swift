import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct ACPUserInputRequest: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case cursor(id: JSONRPCID, params: ACPQuestionRequestParams)
        case elicitation(id: JSONRPCID, params: ACPElicitationRequestParams)
        /// A visual aid's question. Never queued on the elicitation coordinator.
        case visualAid(UUID)
    }

    public enum Mode: Equatable, Sendable {
        case form
        case url(URLRequest)
    }

    public struct URLRequest: Equatable, Sendable {
        public let elicitationId: String
        public let url: URL

        public init(elicitationId: String, url: URL) {
            self.elicitationId = elicitationId
            self.url = url
        }
    }

    public let id: UUID
    public let source: Source
    public let title: String?
    public let message: String
    public let fields: [ACPUserInputField]
    public let mode: Mode

    public enum Delivery: Equatable, Sendable {
        /// The agent waits for the answer.
        case blocking
        /// The agent keeps working; the answer is optional and turn-bound.
        case optional
    }

    public var delivery: Delivery {
        switch source {
        case .elicitation(_, let params):
            return params.isAsyncDelivery && mode == .form ? .optional : .blocking
        case .cursor, .visualAid:
            return .blocking
        }
    }

    public var isBlocking: Bool { delivery == .blocking }

    public struct FieldGroup: Identifiable, Equatable, Sendable {
        public let field: ACPUserInputField
        public let note: ACPUserInputField?
        public var id: String { field.key }
    }

    /// Fields in display order with each note under its question. A note whose
    /// question is missing stays its own group.
    public var fieldGroups: [FieldGroup] {
        let keys = Set(fields.map(\.key))
        var notes: [String: ACPUserInputField] = [:]
        for field in fields {
            if let q = field.schema.noteForQuestion, q != field.key, keys.contains(q), notes[q] == nil {
                notes[q] = field
            }
        }
        let attached = Set(notes.values.map(\.key))
        return fields
            .filter { !attached.contains($0.key) }
            .map { FieldGroup(field: $0, note: notes[$0.key]) }
    }

    /// The option codex-acp adds when a question accepts an own answer.
    public static let ownAnswerOptionConst = "None of the above"

    /// The text codex-acp replays into the transcript for an answered optional
    /// form (`userInputAnswerText` / `displayReplies`), or nil when no
    /// question has an answer.
    public func optionalAnswerTranscriptText(_ content: [String: ACPElicitationValue]) -> String? {
        func string(_ key: String?) -> String? {
            guard let key, case .string(let value)? = content[key] else { return nil }
            return value
        }
        let blocks: [String] = fieldGroups.compactMap { group in
            guard group.field.schema.noteForQuestion == nil else { return nil }
            var parts: [String] = []
            if let choice = string(group.field.key), choice != Self.ownAnswerOptionConst,
               !choice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(choice)
            }
            if let note = string(group.note?.key)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !note.isEmpty {
                parts.append(note)
            }
            guard !parts.isEmpty else { return nil }
            let title = String(String.UnicodeScalarView(group.field.label.unicodeScalars.prefix(512)))
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            return "> \(title)\n\n" + parts.joined(separator: "\n\n")
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    public static func cursor(_ request: ACPQuestionRequest) -> Self {
        let fields = request.params.questions.map { question in
            let options = question.options.map {
                ACPElicitationOption(const: $0.id, title: $0.label, description: nil)
            }
            let schema = ACPUserInputField.Schema(
                type: question.allowMultiple == true ? "array" : "string",
                title: question.prompt,
                description: nil,
                minLength: nil,
                maxLength: nil,
                pattern: nil,
                format: nil,
                minimum: nil,
                maximum: nil,
                minItems: question.allowMultiple == true ? 1 : nil,
                maxItems: nil,
                options: options,
                defaultValue: nil,
                isSecret: false
            )
            return ACPUserInputField(key: question.id, required: true, schema: schema)
        }
        return .init(
            id: UUID(),
            source: .cursor(id: request.id, params: request.params),
            title: request.params.title,
            message: request.params.title ?? "The agent needs your input.",
            fields: fields,
            mode: .form
        )
    }

    public static func elicitation(_ request: ACPElicitationRequest) -> Self? {
        let params = request.params
        switch params.mode {
        case "form":
            guard let schema = params.requestedSchema else { return nil }
            let required = Set(schema.required ?? [])
            guard schema.propertiesAreValid,
                  required.isSubset(of: Set(schema.properties.keys))
            else { return nil }
            let fields = schema.properties
                .map { key, property in
                    ACPUserInputField(
                        key: key,
                        required: required.contains(key),
                        schema: .init(property)
                    )
                }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            return .init(
                id: UUID(),
                source: .elicitation(id: request.id, params: params),
                title: schema.title,
                message: params.message,
                fields: fields,
                mode: .form
            )
        case "url":
            guard let elicitationId = params.elicitationId,
                  let rawURL = params.url,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil
            else { return nil }
            return .init(
                id: UUID(),
                source: .elicitation(id: request.id, params: params),
                title: nil,
                message: params.message,
                fields: [],
                mode: .url(.init(elicitationId: elicitationId, url: url))
            )
        default:
            return nil
        }
    }

    public init(id: UUID, source: Source, title: String?, message: String, fields: [ACPUserInputField], mode: Mode) {
        self.id = id
        self.source = source
        self.title = title
        self.message = message
        self.fields = fields
        self.mode = mode
    }
}

public struct ACPUserInputField: Identifiable, Equatable, Sendable {
    public struct Schema: Equatable, Sendable {
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
        public let options: [ACPElicitationOption]
        public let defaultValue: AnyCodable?
        public let isSecret: Bool
        /// The question accepts an own answer through its note field.
        public let acceptsOwnAnswer: Bool
        /// Set on a note field: the key of the question it annotates.
        public let noteForQuestion: String?

        public init(
            type: String,
            title: String?,
            description: String?,
            minLength: Int?,
            maxLength: Int?,
            pattern: String?,
            format: String?,
            minimum: Double?,
            maximum: Double?,
            minItems: Int?,
            maxItems: Int?,
            options: [ACPElicitationOption],
            defaultValue: AnyCodable?,
            isSecret: Bool,
            acceptsOwnAnswer: Bool = false,
            noteForQuestion: String? = nil
        ) {
            self.type = type
            self.title = title
            self.description = description
            self.minLength = minLength
            self.maxLength = maxLength
            self.pattern = pattern
            self.format = format
            self.minimum = minimum
            self.maximum = maximum
            self.minItems = minItems
            self.maxItems = maxItems
            self.options = options
            self.defaultValue = defaultValue
            self.isSecret = isSecret
            self.acceptsOwnAnswer = acceptsOwnAnswer
            self.noteForQuestion = noteForQuestion
        }

        public init(_ property: ACPElicitationPropertySchema) {
            type = property.type
            title = property.title
            description = property.description
            minLength = property.minLength
            maxLength = property.maxLength
            pattern = property.pattern
            format = property.format
            minimum = property.minimum
            maximum = property.maximum
            minItems = property.minItems
            maxItems = property.maxItems
            isSecret = property.isSecret
            acceptsOwnAnswer = property.acceptsOwnAnswer
            noteForQuestion = property.noteQuestionId
            if let titled = property.oneOf {
                options = titled
            } else if let values = property.values {
                options = values.map { .init(const: $0, title: nil, description: nil) }
            } else if let titled = property.items?.anyOf {
                options = titled
            } else if let values = property.items?.values {
                options = values.map { .init(const: $0, title: nil, description: nil) }
            } else {
                options = []
            }
            defaultValue = property.defaultValue
        }
    }

    public let key: String
    public let required: Bool
    public let schema: Schema

    public var id: String { key }
    public var label: String { schema.title.nonEmpty ?? key }
    public var isSupported: Bool {
        switch schema.type {
        case "string", "number", "integer", "boolean": return true
        // An array with nothing to pick from can still be answered with an
        // empty selection, which JSON Schema accepts unless `minItems`
        // demands entries the form has no way to supply.
        case "array": return !schema.options.isEmpty || (schema.minItems ?? 0) == 0
        default: return false
        }
    }

    public init(key: String, required: Bool, schema: Schema) {
        self.key = key
        self.required = required
        self.schema = schema
    }
}

public struct ACPURLElicitationWait: Identifiable, Equatable, Sendable {
    public let id: String
    public let requestId: UUID
    public let message: String
    public let url: URL

    public init(id: String, requestId: UUID, message: String, url: URL) {
        self.id = id
        self.requestId = requestId
        self.message = message
        self.url = url
    }
}

public enum ACPUserInputAction: Equatable, Sendable {
    case submit([String: ACPElicitationValue])
    case decline
    case cancel
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
