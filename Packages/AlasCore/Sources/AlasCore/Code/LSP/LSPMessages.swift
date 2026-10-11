import Foundation

// MARK: - Envelope

public enum LSPID: Hashable, Codable, Sendable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i)
        return }
        if let s = try? c.decode(String.self) { self = .string(s)
        return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "id must be int or string")
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

// Stored value is typed `Any`. Callers MUST pass only Sendable payloads;
// the LSP client only uses Codable shapes (dictionaries of primitives,
// integers, strings, bools), all of which are Sendable in practice.
public struct AnyEncodable: @unchecked Sendable, Encodable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Encodable:
            try v.encode(to: encoder)
        case let v as [String: Any]:
            try c.encode(v.mapValues(AnyEncodable.init))
        case let v as [Any]:
            try c.encode(v.map(AnyEncodable.init))
        case let v as Int: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as Bool: try c.encode(v)
        case let v as Double: try c.encode(v)
        case Optional<Any>.none: try c.encodeNil()
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
}

public struct LSPRequest: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let id: LSPID
    public let method: String
    public let params: AnyEncodable?

    public init(id: LSPID, method: String, params: AnyEncodable?) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct LSPNotification: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let method: String
    public let params: AnyEncodable?

    public init(method: String, params: AnyEncodable?) {
        self.method = method
        self.params = params
    }
}

public struct LSPResponseError: Codable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct LSPResponse: Decodable, Sendable {
    public let id: LSPID
    public let result: Data?      // raw JSON for caller-decoded shapes
    public let error: LSPResponseError?

    public enum CodingKeys: String, CodingKey, Sendable { case id, result, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(LSPID.self, forKey: .id)
        self.error = try c.decodeIfPresent(LSPResponseError.self, forKey: .error)
        if let raw = try c.decodeIfPresent(JSONValue.self, forKey: .result) {
            self.result = try JSONEncoder().encode(raw)
        } else {
            self.result = nil
        }
    }
}

// Tiny JSON ADT used to preserve `result` payload SHAPE so callers can
// re-decode into structured types. NOT byte-faithful: object key order
// is undefined; whole-valued floats round-trip as integers; integers
// outside Int's range silently downgrade to Double.
public indirect enum JSONValue: Codable, Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null
        return }
        if let v = try? c.decode(Bool.self) { self = .bool(v)
        return }
        if let v = try? c.decode(Int.self) { self = .int(v)
        return }
        if let v = try? c.decode(Double.self) { self = .double(v)
        return }
        if let v = try? c.decode(String.self) { self = .string(v)
        return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v)
        return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v)
        return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown JSON value")
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - Common shapes

public struct LSPPosition: Codable, Hashable, Sendable {
    public let line: Int          // 0-based
    public let character: Int     // UTF-16 code units, 0-based per spec

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct LSPRange: Codable, Hashable, Sendable {
    public let start: LSPPosition
    public let end: LSPPosition

    public var json: [String: Any] {
        [
            "start": ["line": start.line, "character": start.character],
            "end": ["line": end.line, "character": end.character]
        ]
    }

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

public struct LSPLocation: Codable, Hashable, Sendable {
    public let uri: String
    public let range: LSPRange

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }
}

public struct LSPLocationLink: Codable, Hashable, Sendable {
    public let targetUri: String
    public let targetRange: LSPRange
    public let targetSelectionRange: LSPRange

    public init(targetUri: String, targetRange: LSPRange, targetSelectionRange: LSPRange) {
        self.targetUri = targetUri
        self.targetRange = targetRange
        self.targetSelectionRange = targetSelectionRange
    }
}

// MARK: - Pull Diagnostics

public enum LSPDocumentDiagnosticReportKind: String, Codable, Sendable {
    case full = "full"
    case unchanged = "unchanged"
}

public struct LSPFullDocumentDiagnosticReport: Codable, Sendable {
    public let kind: LSPDocumentDiagnosticReportKind
    public let resultId: String?
    public let items: [LSPDiagnostic]

    public init(kind: LSPDocumentDiagnosticReportKind, resultId: String?, items: [LSPDiagnostic]) {
        self.kind = kind
        self.resultId = resultId
        self.items = items
    }
}

public struct LSPUnchangedDocumentDiagnosticReport: Codable, Sendable {
    public let kind: LSPDocumentDiagnosticReportKind
    public let resultId: String

    public init(kind: LSPDocumentDiagnosticReportKind, resultId: String) {
        self.kind = kind
        self.resultId = resultId
    }
}

// MARK: - Hover / Definition / Symbols / Diagnostics

public struct LSPHoverResult: Decodable, Sendable {
    public let contents: LSPMarkup
    public let range: LSPRange?

    public init(contents: LSPMarkup, range: LSPRange?) {
        self.contents = contents
        self.range = range
    }
}

public enum LSPMarkup: Decodable, Sendable {
    case markupContent(kind: String, value: String)
    case plain(String)

    public init(from decoder: Decoder) throws {
        // 1. Plain string.
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = .plain(s)
            return
        }
        // 2. `MarkedString[]` (legacy spec form) or any mixed array of
        //    strings / objects. Concatenate the rendered values into one
        //    block — the hover popover shows a single string.
        if var arr = try? decoder.unkeyedContainer() {
            var pieces: [String] = []
            while !arr.isAtEnd {
                if let s = try? arr.decode(String.self) {
                    pieces.append(s)
                } else if let nested = try? arr.decode(LSPMarkup.self) {
                    switch nested {
                    case .plain(let p):
                        pieces.append(p)
                    case .markupContent(let kind, let v):
                        if kind == "markdown" || kind == "plaintext" {
                            pieces.append(v)
                        } else {
                            let fence = LSPMarkup.longestBacktickRun(in: v)
                            pieces.append("\(fence)\(kind)\n\(v)\n\(fence)")
                        }
                    }
                } else {
                    _ = try? arr.decode(JSONValue.self)  // skip unknown
                }
            }
            self = .markupContent(kind: "markdown", value: pieces.joined(separator: "\n\n"))
            return
        }
        // 3. Object form. `MarkupContent` is `{kind, value}`; legacy
        //    `MarkedString` is `{language, value}`. Treat the latter as
        //    `markupContent` with `language` standing in for `kind`.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try? c.decode(String.self, forKey: .kind),
           let value = try? c.decode(String.self, forKey: .value) {
            self = .markupContent(kind: kind, value: value)
            return
        }
        if let lang = try? c.decode(String.self, forKey: .language),
           let value = try? c.decode(String.self, forKey: .value) {
            self = .markupContent(kind: lang, value: value)
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: CodingKeys.value, in: c,
            debugDescription: "unknown hover content shape"
        )
    }

    public enum CodingKeys: String, CodingKey, Sendable { case kind, value, language }

    public static func longestBacktickRun(in text: String) -> String {
        var longest = 0
        var current = 0
        for ch in text {
            if ch == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        let count = max(3, longest + 1)
        return String(repeating: "`", count: count)
    }
}

public struct LSPDocumentSymbol: Decodable, Sendable {
    public let name: String
    public let detail: String?
    public let kind: Int
    public let range: LSPRange
    public let selectionRange: LSPRange
    public let children: [LSPDocumentSymbol]?

    public init(name: String, detail: String?, kind: Int, range: LSPRange, selectionRange: LSPRange, children: [LSPDocumentSymbol]?) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange
        self.children = children
    }
}

public enum LSPDiagnosticCode: Hashable, Sendable {
    case number(String)
    case string(String)

    public var displayValue: String {
        switch self {
        case .number(let value), .string(let value): value
        }
    }

    public init?(wireValue: LSPJSONValue?) {
        switch wireValue {
        case .number(let value): self = .number(value)
        case .string(let value): self = .string(value)
        default: return nil
        }
    }
}

public struct LSPDiagnosticCodeDescription: Codable, Hashable, Sendable {
    public let href: String

    public init(href: String) {
        self.href = href
    }
}

public struct LSPDiagnosticRelatedInformation: Codable, Hashable, Sendable {
    public let location: LSPLocation
    public let message: String

    public init(location: LSPLocation, message: String) {
        self.location = location
        self.message = message
    }
}

public struct LSPDiagnostic: Codable, Hashable, Sendable {
    /// Original protocol fields, including numeric codes, tags, related information and opaque data.
    public var wireValue: LSPJSONValue?
    public let range: LSPRange
    public let severity: Int?       // 1=error 2=warning 3=info 4=hint
    public let code: LSPDiagnosticCode?
    public let codeDescription: LSPDiagnosticCodeDescription?
    public let source: String?
    public let tags: [Int]?
    public let relatedInformation: [LSPDiagnosticRelatedInformation]?
    public let data: LSPJSONValue?
    public let message: String

    public enum CodingKeys: String, CodingKey, Sendable {
        case range, severity, code, codeDescription, source, tags, relatedInformation, data, message
    }

    public init(wireValue: LSPJSONValue) throws {
        let raw = try wireValue.encodedData()
        let c = try JSONDecoder().decode(DecodedFields.self, from: raw)
        self.wireValue = wireValue
        range = c.range
        severity = c.severity
        code = LSPDiagnosticCode(wireValue: wireValue["code"])
        codeDescription = c.codeDescription
        source = c.source
        tags = c.tags
        relatedInformation = c.relatedInformation
        data = wireValue["data"]
        message = c.message
    }

    public init(from decoder: Decoder) throws {
        wireValue = try? LSPJSONValue(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        range = try c.decode(LSPRange.self, forKey: .range)
        severity = try c.decodeIfPresent(Int.self, forKey: .severity)
        code = LSPDiagnosticCode(wireValue: wireValue?["code"])
        codeDescription = try c.decodeIfPresent(LSPDiagnosticCodeDescription.self, forKey: .codeDescription)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        tags = try c.decodeIfPresent([Int].self, forKey: .tags)
        relatedInformation = try c.decodeIfPresent([LSPDiagnosticRelatedInformation].self, forKey: .relatedInformation)
        data = wireValue?["data"]
        message = try c.decode(String.self, forKey: .message)
    }
    public func encode(to encoder: Encoder) throws {
        if let wireValue { try wireValue.encode(to: encoder)
        return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(range, forKey: .range)
        try c.encodeIfPresent(severity, forKey: .severity)
        if let code {
            switch code {
            case .number(let value):
                guard let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
                    throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Invalid diagnostic code"))
                }
                try c.encode(number, forKey: .code)
            case .string(let value): try c.encode(value, forKey: .code)
            }
        }
        try c.encodeIfPresent(codeDescription, forKey: .codeDescription)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(relatedInformation, forKey: .relatedInformation)
        if let data { try data.encode(to: c.superEncoder(forKey: .data)) }
        try c.encode(message, forKey: .message)
    }

    private struct DecodedFields: Decodable {
        let range: LSPRange
        let severity: Int?
        let codeDescription: LSPDiagnosticCodeDescription?
        let source: String?
        let tags: [Int]?
        let relatedInformation: [LSPDiagnosticRelatedInformation]?
        let message: String

        public init(range: LSPRange, severity: Int?, codeDescription: LSPDiagnosticCodeDescription?, source: String?, tags: [Int]?, relatedInformation: [LSPDiagnosticRelatedInformation]?, message: String) {
            self.range = range
            self.severity = severity
            self.codeDescription = codeDescription
            self.source = source
            self.tags = tags
            self.relatedInformation = relatedInformation
            self.message = message
        }
    }
}

extension LSPJSONValue {
    public subscript(_ key: String) -> LSPJSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

public struct LSPCommand: Sendable {
    public let title: String
    public let command: String
    public let arguments: [LSPJSONValue]?

    public init(wireValue: LSPJSONValue) throws {
        guard let title = wireValue["title"]?.stringValue, let command = wireValue["command"]?.stringValue else {
            throw LSPError.invalidPayload
        }
        self.title = title
        self.command = command
        if case .array(let arguments) = wireValue["arguments"] { self.arguments = arguments } else { self.arguments = nil }
    }
}

/// Both Command and CodeAction retain their original union shape on the wire.
public struct LSPCodeAction: Codable, Sendable {
    public struct Disabled: Sendable { public let reason: String

        public init(reason: String) {
            self.reason = reason
        }}
    public let wireValue: LSPJSONValue
    public let title: String
    public let kind: String?
    public let diagnostics: [LSPJSONValue]?
    public let disabled: Disabled?
    public let edit: LSPWorkspaceEdit?
    public let command: LSPCommand?
    public let data: LSPJSONValue?
    public let isPreferred: Bool?
    public let isCommand: Bool

    public init(wireValue: LSPJSONValue) throws {
        guard let title = wireValue["title"]?.stringValue else { throw LSPError.invalidPayload }
        self.wireValue = wireValue
        self.title = title
        kind = wireValue["kind"]?.stringValue
        if case .array(let values) = wireValue["diagnostics"] { diagnostics = values } else { diagnostics = nil }
        disabled = wireValue["disabled"]?["reason"]?.stringValue.map(Disabled.init)
        if let value = wireValue["edit"], value != .null {
            edit = try JSONDecoder().decode(LSPWorkspaceEdit.self, from: value.encodedData())
        } else { edit = nil }
        isCommand = wireValue["command"]?.stringValue != nil
        if isCommand { command = try LSPCommand(wireValue: wireValue) }
        else if let value = wireValue["command"], value != .null { command = try LSPCommand(wireValue: value) }
        else { command = nil }
        data = wireValue["data"]
        if case .bool(let value) = wireValue["isPreferred"] { isPreferred = value } else { isPreferred = nil }
    }

    public init(from decoder: Decoder) throws { try self.init(wireValue: LSPJSONValue(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try wireValue.encode(to: encoder) }

    public static func decodeList(_ data: Data?) throws -> [LSPCodeAction] {
        guard let data else { return [] }
        let value = try LSPJSONValue.decode(from: data)
        if value == .null { return [] }
        guard case .array(let values) = value else { throw LSPError.invalidPayload }
        return try values.map { try LSPCodeAction(wireValue: $0) }
    }
}

public struct LSPPublishDiagnosticsParams: Decodable, Sendable {
    public let uri: String
    public let diagnostics: [LSPDiagnostic]

    public init(uri: String, diagnostics: [LSPDiagnostic]) {
        self.uri = uri
        self.diagnostics = diagnostics
    }
}

extension LSPDiagnostic {
    public static func decodeWire(_ values: [LSPJSONValue]) throws -> [LSPDiagnostic] {
        try values.map(LSPDiagnostic.init(wireValue:))
    }
}

// MARK: - Formatting

public struct LSPFormattingOptions: Codable, Hashable, Sendable {
    public let tabSize: Int
    public let insertSpaces: Bool

    public init(tabSize: Int, insertSpaces: Bool) {
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
    }
}

public struct LSPDocumentFormattingParams: Codable, Hashable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let options: LSPFormattingOptions

    public init(textDocument: LSPTextDocumentIdentifier, options: LSPFormattingOptions) {
        self.textDocument = textDocument
        self.options = options
    }
}

public struct LSPTextDocumentIdentifier: Codable, Hashable, Sendable {
    public let uri: String

    public init(uri: String) {
        self.uri = uri
    }
}

public struct LSPTextEdit: Codable, Hashable, Sendable {
    public let range: LSPRange
    public let newText: String
    public let annotationID: String?

    public init(range: LSPRange, newText: String, annotationID: String? = nil) {
        self.range = range
        self.newText = newText
        self.annotationID = annotationID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.newText = try container.decode(String.self, forKey: .newText)
        self.annotationID = try container.decodeIfPresent(String.self, forKey: .annotationId)
        if let range = try container.decodeIfPresent(LSPRange.self, forKey: .range) {
            self.range = range
        } else if let replace = try container.decodeIfPresent(LSPRange.self, forKey: .replace) {
            self.range = replace
        } else {
            self.range = try container.decode(LSPRange.self, forKey: .insert)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(range, forKey: .range)
        try container.encode(newText, forKey: .newText)
        try container.encodeIfPresent(annotationID, forKey: .annotationId)
    }

    private enum CodingKeys: String, CodingKey {
        case range
        case newText
        case insert
        case replace
        case annotationId
    }
}

// MARK: - Completion

public struct LSPCompletionParams: Codable, Hashable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let position: LSPPosition
    public let context: LSPCompletionContext?

    public init(textDocument: LSPTextDocumentIdentifier, position: LSPPosition, context: LSPCompletionContext?) {
        self.textDocument = textDocument
        self.position = position
        self.context = context
    }
}

public struct LSPCompletionContext: Codable, Hashable, Sendable {
    public let triggerKind: LSPCompletionTriggerKind
    public let triggerCharacter: String?

    public init(triggerKind: LSPCompletionTriggerKind, triggerCharacter: String?) {
        self.triggerKind = triggerKind
        self.triggerCharacter = triggerCharacter
    }
}

public enum LSPCompletionTriggerKind: Int, Codable, Hashable, Sendable {
    case invoked = 1
    case triggerCharacter = 2
    case triggerForIncompleteCompletions = 3
}

public enum LSPInsertTextFormat: Int, Codable, Hashable, Sendable {
    case plainText = 1
    case snippet = 2
}

public struct LSPInsertReplaceEdit: Codable, Equatable, Sendable {
    public let newText: String
    public let insert: LSPRange
    public let replace: LSPRange

    public init(newText: String, insert: LSPRange, replace: LSPRange) {
        self.newText = newText
        self.insert = insert
        self.replace = replace
    }
}

public struct LSPCompletionItem: Codable, Sendable {
    public let label: String
    public let kind: Int?
    public let detail: String?
    public let documentation: LSPMarkup?
    public let sortText: String?
    public let filterText: String?
    public let insertText: String?
    public let insertTextFormat: LSPInsertTextFormat?
    public let textEdit: LSPTextEdit?
    public let additionalTextEdits: [LSPTextEdit]?
    public var insertReplaceEdit: LSPInsertReplaceEdit? = nil
    public var insertTextMode: Int? = nil
    public var command: LSPCommand? = nil
    public var data: LSPJSONValue? = nil
    private var originalWireValue: LSPJSONValue? = nil

    public var wireValue: LSPJSONValue {
        if let originalWireValue { return originalWireValue }
        var fields: [String: LSPJSONValue] = ["label": .string(label)]
        for (key, value) in [("detail", detail), ("sortText", sortText), ("filterText", filterText), ("insertText", insertText)] {
            if let value { fields[key] = .string(value) }
        }
        if let kind { fields["kind"] = .number(String(kind)) }
        if let insertTextFormat { fields["insertTextFormat"] = .number(String(insertTextFormat.rawValue)) }
        if let insertTextMode { fields["insertTextMode"] = .number(String(insertTextMode)) }
        if let textEdit { fields["textEdit"] = try? LSPJSONValue.decode(from: JSONEncoder().encode(textEdit)) }
        if let insertReplaceEdit { fields["textEdit"] = try? LSPJSONValue.decode(from: JSONEncoder().encode(insertReplaceEdit)) }
        if let additionalTextEdits { fields["additionalTextEdits"] = try? LSPJSONValue.decode(from: JSONEncoder().encode(additionalTextEdits)) }
        if let documentation {
            switch documentation {
            case .plain(let text): fields["documentation"] = .string(text)
            case .markupContent(let kind, let value): fields["documentation"] = .object(["kind": .string(kind), "value": .string(value)])
            }
        }
        fields["data"] = data
        if let command {
            var value: [String: LSPJSONValue] = ["title": .string(command.title), "command": .string(command.command)]
            if let arguments = command.arguments { value["arguments"] = .array(arguments) }
            fields["command"] = .object(value)
        }
        return .object(fields)
    }

    public init(
        label: String,
        kind: Int?,
        detail: String?,
        documentation: LSPMarkup?,
        sortText: String?,
        filterText: String?,
        insertText: String?,
        insertTextFormat: LSPInsertTextFormat?,
        textEdit: LSPTextEdit?,
        additionalTextEdits: [LSPTextEdit]?
    ) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.sortText = sortText
        self.filterText = filterText
        self.insertText = insertText
        self.insertTextFormat = insertTextFormat
        self.textEdit = textEdit
        self.additionalTextEdits = additionalTextEdits
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case label
        case kind
        case detail
        case documentation
        case sortText
        case filterText
        case insertText
        case insertTextFormat
        case textEdit
        case additionalTextEdits
    }

    public init(wireValue: LSPJSONValue) throws {
        guard let label = wireValue["label"]?.stringValue else { throw LSPError.invalidPayload }
        func decode<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
            guard let value = wireValue[key], value != .null else { return nil }
            return try JSONDecoder().decode(type, from: value.encodedData())
        }
        self.label = label
        kind = try decode("kind", as: Int.self)
        detail = try decode("detail", as: String.self)
        documentation = try decode("documentation", as: LSPMarkup.self)
        sortText = try decode("sortText", as: String.self)
        filterText = try decode("filterText", as: String.self)
        insertText = try decode("insertText", as: String.self)
        insertTextFormat = try decode("insertTextFormat", as: LSPInsertTextFormat.self)
        insertTextMode = try decode("insertTextMode", as: Int.self)
        if wireValue["textEdit"]?["insert"] != nil {
            insertReplaceEdit = try decode("textEdit", as: LSPInsertReplaceEdit.self)
            textEdit = insertReplaceEdit.map { LSPTextEdit(range: $0.replace, newText: $0.newText) }
        } else { textEdit = try decode("textEdit", as: LSPTextEdit.self) }
        additionalTextEdits = try decode("additionalTextEdits", as: [LSPTextEdit].self)
        if let command = wireValue["command"], command != .null { self.command = try LSPCommand(wireValue: command) }
        data = wireValue["data"]
        originalWireValue = wireValue
    }

    public init(from decoder: Decoder) throws { try self.init(wireValue: LSPJSONValue(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try wireValue.encode(to: encoder) }

    public func mergingResolved(_ resolved: LSPCompletionItem) throws -> LSPCompletionItem {
        guard case .object(let original) = wireValue, case .object(let changes) = resolved.wireValue else { throw LSPError.invalidPayload }
        return try LSPCompletionItem(wireValue: .object(original.merging(changes) { _, new in new }))
    }
}

public struct LSPCompletionResult: Decodable, Sendable {
    public let isIncomplete: Bool
    public let items: [LSPCompletionItem]

    public init(isIncomplete: Bool, items: [LSPCompletionItem]) {
        self.isIncomplete = isIncomplete
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        try self.init(wireValue: LSPJSONValue(from: decoder))
    }

    public init(wireValue: LSPJSONValue) throws {
        if case .array(let values) = wireValue {
            isIncomplete = false
            items = try values.map { try LSPCompletionItem(wireValue: $0) }
            return
        }
        guard case .array(let values) = wireValue["items"] else { throw LSPError.invalidPayload }
        isIncomplete = wireValue["isIncomplete"] == .bool(true)
        let defaults = wireValue["itemDefaults"]
        items = try values.map { value in
            guard case .object(var fields) = value else { throw LSPError.invalidPayload }
            for key in ["commitCharacters", "insertTextFormat", "insertTextMode", "data"] where fields[key] == nil {
                fields[key] = defaults?[key]
            }
            if fields["textEdit"] == nil, let range = defaults?["editRange"] {
                let text = fields["textEditText"] ?? fields["label"] ?? .string("")
                if range["insert"] != nil {
                    fields["textEdit"] = .object(["insert": range["insert"] ?? .null, "replace": range["replace"] ?? .null, "newText": text])
                } else { fields["textEdit"] = .object(["range": range, "newText": text]) }
            }
            return try LSPCompletionItem(wireValue: .object(fields))
        }
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case isIncomplete
        case items
    }
}
