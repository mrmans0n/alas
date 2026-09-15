import Foundation

/// A JSON value for opaque protocol payloads.
///
/// ``decode(from:)`` and ``encodedData()`` preserve arbitrary numeric tokens
/// exactly. Generic `Codable` preserves Foundation-representable numeric values,
/// but may canonicalize their spelling because `Decoder` does not expose the
/// original JSON token.
indirect enum LSPJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(String)
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
            self = .number(NSDecimalNumber(decimal: value).stringValue)
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
        case .number(let value):
            guard let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid JSON number token"
                ))
            }
            try container.encode(number)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses JSON bytes directly so arbitrary numeric tokens never pass through Decimal or Double.
    static func decode(from data: Data) throws -> LSPJSONValue {
        var parser = LSPJSONValueParser(data: data)
        return try parser.parseDocument()
    }

    /// Encodes this value while writing number tokens verbatim.
    func encodedData() throws -> Data {
        var encoder = LSPJSONValueEncoder()
        try encoder.append(self)
        return encoder.data
    }
}

private enum LSPJSONValueError: Swift.Error {
    case malformedJSON
    case duplicateObjectKey
    case containerNestingLimitExceeded
}

private struct LSPJSONValueParser {
    private static let maximumContainerDepth = 128

    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parseDocument() throws -> LSPJSONValue {
        skipWhitespace()
        let value = try parseValue(containerDepth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw LSPJSONValueError.malformedJSON }
        return value
    }

    private mutating func parseValue(containerDepth: Int) throws -> LSPJSONValue {
        guard index < bytes.count else { throw LSPJSONValueError.malformedJSON }
        switch bytes[index] {
        case 110:
            try consumeLiteral([110, 117, 108, 108])
            return .null
        case 116:
            try consumeLiteral([116, 114, 117, 101])
            return .bool(true)
        case 102:
            try consumeLiteral([102, 97, 108, 115, 101])
            return .bool(false)
        case 34:
            return .string(try parseString())
        case 91:
            guard containerDepth < Self.maximumContainerDepth else {
                throw LSPJSONValueError.containerNestingLimitExceeded
            }
            return .array(try parseArray(containerDepth: containerDepth + 1))
        case 123:
            guard containerDepth < Self.maximumContainerDepth else {
                throw LSPJSONValueError.containerNestingLimitExceeded
            }
            return .object(try parseObject(containerDepth: containerDepth + 1))
        case 45, 48...57:
            return .number(try parseNumber())
        default:
            throw LSPJSONValueError.malformedJSON
        }
    }

    private mutating func parseArray(containerDepth: Int) throws -> [LSPJSONValue] {
        index += 1 // [
        skipWhitespace()
        if consume(93) { return [] }
        var values: [LSPJSONValue] = []
        while true {
            skipWhitespace()
            values.append(try parseValue(containerDepth: containerDepth))
            skipWhitespace()
            if consume(93) { return values }
            guard consume(44) else { throw LSPJSONValueError.malformedJSON }
        }
    }

    private mutating func parseObject(containerDepth: Int) throws -> [String: LSPJSONValue] {
        index += 1 // {
        skipWhitespace()
        if consume(125) { return [:] }
        var values: [String: LSPJSONValue] = [:]
        while true {
            skipWhitespace()
            let key = try parseString()
            guard values[key] == nil else { throw LSPJSONValueError.duplicateObjectKey }
            skipWhitespace()
            guard consume(58) else { throw LSPJSONValueError.malformedJSON }
            skipWhitespace()
            values[key] = try parseValue(containerDepth: containerDepth)
            skipWhitespace()
            if consume(125) { return values }
            guard consume(44) else { throw LSPJSONValueError.malformedJSON }
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        guard consume(34) else { throw LSPJSONValueError.malformedJSON }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 {
                index += 1
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            if byte == 92 {
                index += 1
                guard index < bytes.count else { throw LSPJSONValueError.malformedJSON }
                if bytes[index] == 117 {
                    guard index + 4 < bytes.count else { throw LSPJSONValueError.malformedJSON }
                    index += 5
                } else {
                    index += 1
                }
            } else {
                guard byte >= 32 else { throw LSPJSONValueError.malformedJSON }
                index += 1
            }
        }
        throw LSPJSONValueError.malformedJSON
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        _ = consume(45)
        guard index < bytes.count else { throw LSPJSONValueError.malformedJSON }
        if consume(48) {
            guard index == bytes.count || !isDigit(bytes[index]) else { throw LSPJSONValueError.malformedJSON }
        } else {
            guard consumeDigit(in: 49...57) else { throw LSPJSONValueError.malformedJSON }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if consume(46) {
            guard consumeDigit(in: 48...57) else { throw LSPJSONValueError.malformedJSON }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
            index += 1
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
            guard consumeDigit(in: 48...57) else { throw LSPJSONValueError.malformedJSON }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        guard let number = String(bytes: bytes[start..<index], encoding: .utf8) else {
            throw LSPJSONValueError.malformedJSON
        }
        return number
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) throws {
        guard bytes[index...].starts(with: literal) else { throw LSPJSONValueError.malformedJSON }
        index += literal.count
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func consumeDigit(in range: ClosedRange<UInt8>) -> Bool {
        guard index < bytes.count, range.contains(bytes[index]) else { return false }
        index += 1
        return true
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
}

private struct LSPJSONValueEncoder {
    private(set) var data = Data()

    mutating func append(_ value: LSPJSONValue) throws {
        switch value {
        case .null:
            data.append(contentsOf: [110, 117, 108, 108])
        case .bool(true):
            data.append(contentsOf: [116, 114, 117, 101])
        case .bool(false):
            data.append(contentsOf: [102, 97, 108, 115, 101])
        case .number(let token):
            guard case .number = try LSPJSONValue.decode(from: Data(token.utf8)) else {
                throw LSPJSONValueError.malformedJSON
            }
            data.append(contentsOf: token.utf8)
        case .string(let string):
            data.append(try JSONEncoder().encode(string))
        case .array(let values):
            data.append(91)
            for (index, item) in values.enumerated() {
                if index > 0 { data.append(44) }
                try append(item)
            }
            data.append(93)
        case .object(let values):
            data.append(123)
            for (index, key) in values.keys.sorted().enumerated() {
                if index > 0 { data.append(44) }
                data.append(try JSONEncoder().encode(key))
                data.append(58)
                try append(values[key]!)
            }
            data.append(125)
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
