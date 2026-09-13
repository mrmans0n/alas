import Foundation

/// A lossless-enough JSON value for protocol fields that Alas does not yet interpret.
/// Decimal avoids routing numeric payloads through display strings or binary doubles.
indirect enum LSPJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([LSPJSONValue])
    case object([String: LSPJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LSPJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: LSPJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

struct LSPWorkspaceEdit: Codable, Equatable, Sendable {
    let changes: [String: [LSPTextEdit]]?
    let documentChanges: [LSPDocumentChange]?
    let changeAnnotations: [String: LSPChangeAnnotation]?

    init(
        changes: [String: [LSPTextEdit]]? = nil,
        documentChanges: [LSPDocumentChange]? = nil,
        changeAnnotations: [String: LSPChangeAnnotation]? = nil
    ) {
        self.changes = changes
        self.documentChanges = documentChanges
        self.changeAnnotations = changeAnnotations
    }
}

struct LSPVersionedTextDocumentIdentifier: Codable, Equatable, Sendable {
    let uri: String
    let version: Int?
}

struct LSPChangeAnnotation: Codable, Equatable, Sendable {
    let label: String
    let needsConfirmation: Bool
    let description: String?

    init(label: String, needsConfirmation: Bool = false, description: String? = nil) {
        self.label = label
        self.needsConfirmation = needsConfirmation
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case needsConfirmation
        case description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        needsConfirmation = try container.decodeIfPresent(Bool.self, forKey: .needsConfirmation) ?? false
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }
}

struct LSPCreateFileOptions: Codable, Equatable, Sendable {
    let overwrite: Bool
    let ignoreIfExists: Bool

    init(overwrite: Bool = false, ignoreIfExists: Bool = false) {
        self.overwrite = overwrite
        self.ignoreIfExists = ignoreIfExists
    }

    private enum CodingKeys: String, CodingKey { case overwrite, ignoreIfExists }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overwrite = try container.decodeIfPresent(Bool.self, forKey: .overwrite) ?? false
        ignoreIfExists = try container.decodeIfPresent(Bool.self, forKey: .ignoreIfExists) ?? false
    }
}

struct LSPRenameFileOptions: Codable, Equatable, Sendable {
    let overwrite: Bool
    let ignoreIfExists: Bool

    init(overwrite: Bool = false, ignoreIfExists: Bool = false) {
        self.overwrite = overwrite
        self.ignoreIfExists = ignoreIfExists
    }

    private enum CodingKeys: String, CodingKey { case overwrite, ignoreIfExists }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overwrite = try container.decodeIfPresent(Bool.self, forKey: .overwrite) ?? false
        ignoreIfExists = try container.decodeIfPresent(Bool.self, forKey: .ignoreIfExists) ?? false
    }
}

struct LSPDeleteFileOptions: Codable, Equatable, Sendable {
    let recursive: Bool
    let ignoreIfNotExists: Bool

    init(recursive: Bool = false, ignoreIfNotExists: Bool = false) {
        self.recursive = recursive
        self.ignoreIfNotExists = ignoreIfNotExists
    }

    private enum CodingKeys: String, CodingKey { case recursive, ignoreIfNotExists }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recursive = try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
        ignoreIfNotExists = try container.decodeIfPresent(Bool.self, forKey: .ignoreIfNotExists) ?? false
    }
}

enum LSPDocumentChange: Codable, Equatable, Sendable {
    case textDocument(document: LSPVersionedTextDocumentIdentifier, edits: [LSPTextEdit])
    case create(uri: String, options: LSPCreateFileOptions, annotationID: String?)
    case rename(oldURI: String, newURI: String, options: LSPRenameFileOptions, annotationID: String?)
    case delete(uri: String, options: LSPDeleteFileOptions, annotationID: String?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case textDocument
        case edits
        case uri
        case oldUri
        case newUri
        case options
        case annotationId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try container.decodeIfPresent(String.self, forKey: .kind) {
            let annotationID = try container.decodeIfPresent(String.self, forKey: .annotationId)
            switch kind {
            case "create":
                self = .create(
                    uri: try container.decode(String.self, forKey: .uri),
                    options: try container.decodeIfPresent(LSPCreateFileOptions.self, forKey: .options) ?? .init(),
                    annotationID: annotationID
                )
            case "rename":
                self = .rename(
                    oldURI: try container.decode(String.self, forKey: .oldUri),
                    newURI: try container.decode(String.self, forKey: .newUri),
                    options: try container.decodeIfPresent(LSPRenameFileOptions.self, forKey: .options) ?? .init(),
                    annotationID: annotationID
                )
            case "delete":
                self = .delete(
                    uri: try container.decode(String.self, forKey: .uri),
                    options: try container.decodeIfPresent(LSPDeleteFileOptions.self, forKey: .options) ?? .init(),
                    annotationID: annotationID
                )
            default:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unsupported document change kind")
            }
        } else {
            self = .textDocument(
                document: try container.decode(LSPVersionedTextDocumentIdentifier.self, forKey: .textDocument),
                edits: try container.decode([LSPTextEdit].self, forKey: .edits)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .textDocument(let document, let edits):
            try container.encode(document, forKey: .textDocument)
            try container.encode(edits, forKey: .edits)
        case .create(let uri, let options, let annotationID):
            try container.encode("create", forKey: .kind)
            try container.encode(uri, forKey: .uri)
            try container.encode(options, forKey: .options)
            try container.encodeIfPresent(annotationID, forKey: .annotationId)
        case .rename(let oldURI, let newURI, let options, let annotationID):
            try container.encode("rename", forKey: .kind)
            try container.encode(oldURI, forKey: .oldUri)
            try container.encode(newURI, forKey: .newUri)
            try container.encode(options, forKey: .options)
            try container.encodeIfPresent(annotationID, forKey: .annotationId)
        case .delete(let uri, let options, let annotationID):
            try container.encode("delete", forKey: .kind)
            try container.encode(uri, forKey: .uri)
            try container.encode(options, forKey: .options)
            try container.encodeIfPresent(annotationID, forKey: .annotationId)
        }
    }
}
