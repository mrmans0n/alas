import Foundation

struct ACPUserInputRequest: Identifiable, Equatable {
    enum Source: Equatable {
        case cursor(id: JSONRPCID, params: ACPQuestionRequestParams)
        case elicitation(id: JSONRPCID, params: ACPElicitationRequestParams)
    }

    enum Mode: Equatable {
        case form
        case url(URLRequest)
    }

    struct URLRequest: Equatable {
        let elicitationId: String
        let url: URL
    }

    let id: UUID
    let source: Source
    let title: String?
    let message: String
    let fields: [ACPUserInputField]
    let mode: Mode

    static func cursor(_ request: ACPQuestionRequest) -> Self {
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
                defaultValue: nil
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

    static func elicitation(_ request: ACPElicitationRequest) -> Self? {
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
}

struct ACPUserInputField: Identifiable, Equatable {
    struct Schema: Equatable {
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
        let options: [ACPElicitationOption]
        let defaultValue: AnyCodable?

        init(
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
            defaultValue: AnyCodable?
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
        }

        init(_ property: ACPElicitationPropertySchema) {
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

    let key: String
    let required: Bool
    let schema: Schema

    var id: String { key }
    var label: String { schema.title.nonEmpty ?? key }
    var isSupported: Bool {
        switch schema.type {
        case "string", "number", "integer", "boolean": return true
        case "array": return !schema.options.isEmpty
        default: return false
        }
    }
}

struct ACPURLElicitationWait: Identifiable, Equatable {
    let id: String
    let requestId: UUID
    let message: String
    let url: URL
}

enum ACPUserInputAction: Equatable {
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
