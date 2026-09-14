import Foundation

// MARK: - Envelope

enum LSPID: Hashable, Codable, Sendable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i)
        return }
        if let s = try? c.decode(String.self) { self = .string(s)
        return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "id must be int or string")
    }
    func encode(to encoder: Encoder) throws {
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
struct AnyEncodable: @unchecked Sendable, Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
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

struct LSPRequest: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: LSPID
    let method: String
    let params: AnyEncodable?
}

struct LSPNotification: Encodable, Sendable {
    let jsonrpc = "2.0"
    let method: String
    let params: AnyEncodable?
}

struct LSPResponseError: Codable, Sendable {
    let code: Int
    let message: String
}

struct LSPResponse: Decodable, Sendable {
    let id: LSPID
    let result: Data?      // raw JSON for caller-decoded shapes
    let error: LSPResponseError?

    enum CodingKeys: String, CodingKey { case id, result, error }

    init(from decoder: Decoder) throws {
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
indirect enum JSONValue: Codable, Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from decoder: Decoder) throws {
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
    func encode(to encoder: Encoder) throws {
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

struct LSPPosition: Codable, Hashable, Sendable {
    let line: Int          // 0-based
    let character: Int     // UTF-16 code units, 0-based per spec
}

struct LSPRange: Codable, Hashable, Sendable {
    let start: LSPPosition
    let end: LSPPosition

    var json: [String: Any] {
        [
            "start": ["line": start.line, "character": start.character],
            "end": ["line": end.line, "character": end.character]
        ]
    }
}

struct LSPLocation: Codable, Hashable, Sendable {
    let uri: String
    let range: LSPRange
}

struct LSPLocationLink: Codable, Hashable, Sendable {
    let targetUri: String
    let targetRange: LSPRange
    let targetSelectionRange: LSPRange
}

// MARK: - Pull Diagnostics

enum LSPDocumentDiagnosticReportKind: String, Codable {
    case full = "full"
    case unchanged = "unchanged"
}

struct LSPFullDocumentDiagnosticReport: Codable {
    let kind: LSPDocumentDiagnosticReportKind
    let resultId: String?
    let items: [LSPDiagnostic]
}

struct LSPUnchangedDocumentDiagnosticReport: Codable {
    let kind: LSPDocumentDiagnosticReportKind
    let resultId: String
}

// MARK: - Hover / Definition / Symbols / Diagnostics

struct LSPHoverResult: Decodable, Sendable {
    let contents: LSPMarkup
    let range: LSPRange?
}

enum LSPMarkup: Decodable, Sendable {
    case markupContent(kind: String, value: String)
    case plain(String)

    init(from decoder: Decoder) throws {
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

    enum CodingKeys: String, CodingKey { case kind, value, language }

    static func longestBacktickRun(in text: String) -> String {
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

struct LSPDocumentSymbol: Decodable, Sendable {
    let name: String
    let detail: String?
    let kind: Int
    let range: LSPRange
    let selectionRange: LSPRange
    let children: [LSPDocumentSymbol]?
}

struct LSPDiagnostic: Codable, Hashable, Sendable {
    /// Original protocol fields, including numeric codes, tags, related information and opaque data.
    var wireValue: LSPJSONValue?
    let range: LSPRange
    let severity: Int?       // 1=error 2=warning 3=info 4=hint
    let code: String?
    let source: String?
    let message: String

    enum CodingKeys: String, CodingKey { case range, severity, code, source, message }
    init(from decoder: Decoder) throws {
        wireValue = try? LSPJSONValue(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        range = try c.decode(LSPRange.self, forKey: .range)
        severity = try c.decodeIfPresent(Int.self, forKey: .severity)
        if let s = try? c.decodeIfPresent(String.self, forKey: .code) { code = s }
        else if let i = try? c.decodeIfPresent(Int.self, forKey: .code) { code = String(i) }
        else { code = nil }
        source = try c.decodeIfPresent(String.self, forKey: .source)
        message = try c.decode(String.self, forKey: .message)
    }
    func encode(to encoder: Encoder) throws {
        if let wireValue { try wireValue.encode(to: encoder)
        return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(range, forKey: .range)
        try c.encodeIfPresent(severity, forKey: .severity)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(message, forKey: .message)
    }
}

extension LSPJSONValue {
    subscript(_ key: String) -> LSPJSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

struct LSPCommand: Sendable {
    let title: String
    let command: String
    let arguments: [LSPJSONValue]?

    init(wireValue: LSPJSONValue) throws {
        guard let title = wireValue["title"]?.stringValue, let command = wireValue["command"]?.stringValue else {
            throw LSPError.invalidPayload
        }
        self.title = title
        self.command = command
        if case .array(let arguments) = wireValue["arguments"] { self.arguments = arguments } else { self.arguments = nil }
    }
}

/// Both Command and CodeAction retain their original union shape on the wire.
struct LSPCodeAction: Codable, Sendable {
    struct Disabled: Sendable { let reason: String }
    let wireValue: LSPJSONValue
    let title: String
    let kind: String?
    let diagnostics: [LSPJSONValue]?
    let disabled: Disabled?
    let edit: LSPWorkspaceEdit?
    let command: LSPCommand?
    let data: LSPJSONValue?
    let isPreferred: Bool?
    let isCommand: Bool

    init(wireValue: LSPJSONValue) throws {
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

    init(from decoder: Decoder) throws { try self.init(wireValue: LSPJSONValue(from: decoder)) }
    func encode(to encoder: Encoder) throws { try wireValue.encode(to: encoder) }

    static func decodeList(_ data: Data?) throws -> [LSPCodeAction] {
        guard let data else { return [] }
        let value = try LSPJSONValue.decode(from: data)
        if value == .null { return [] }
        guard case .array(let values) = value else { throw LSPError.invalidPayload }
        return try values.map { try LSPCodeAction(wireValue: $0) }
    }
}

struct LSPPublishDiagnosticsParams: Decodable, Sendable {
    let uri: String
    let diagnostics: [LSPDiagnostic]
}

extension LSPDiagnostic {
    static func decodeWire(_ values: [LSPJSONValue]) throws -> [LSPDiagnostic] {
        try values.map { value in
            var diagnostic = try JSONDecoder().decode(LSPDiagnostic.self, from: value.encodedData())
            diagnostic.wireValue = value
            return diagnostic
        }
    }
}

// MARK: - Formatting

struct LSPFormattingOptions: Codable, Hashable, Sendable {
    let tabSize: Int
    let insertSpaces: Bool
}

struct LSPDocumentFormattingParams: Codable, Hashable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let options: LSPFormattingOptions
}

struct LSPTextDocumentIdentifier: Codable, Hashable, Sendable {
    let uri: String
}

struct LSPTextEdit: Codable, Hashable, Sendable {
    let range: LSPRange
    let newText: String
    let annotationID: String?

    init(range: LSPRange, newText: String, annotationID: String? = nil) {
        self.range = range
        self.newText = newText
        self.annotationID = annotationID
    }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

struct LSPCompletionParams: Codable, Hashable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let position: LSPPosition
    let context: LSPCompletionContext?
}

struct LSPCompletionContext: Codable, Hashable, Sendable {
    let triggerKind: LSPCompletionTriggerKind
    let triggerCharacter: String?
}

enum LSPCompletionTriggerKind: Int, Codable, Hashable, Sendable {
    case invoked = 1
    case triggerCharacter = 2
    case triggerForIncompleteCompletions = 3
}

enum LSPInsertTextFormat: Int, Codable, Hashable, Sendable {
    case plainText = 1
    case snippet = 2
}

struct LSPInsertReplaceEdit: Codable, Equatable, Sendable {
    let newText: String
    let insert: LSPRange
    let replace: LSPRange
}

struct LSPCompletionItem: Codable, Sendable {
    let label: String
    let kind: Int?
    let detail: String?
    let documentation: LSPMarkup?
    let sortText: String?
    let filterText: String?
    let insertText: String?
    let insertTextFormat: LSPInsertTextFormat?
    let textEdit: LSPTextEdit?
    let additionalTextEdits: [LSPTextEdit]?
    var insertReplaceEdit: LSPInsertReplaceEdit? = nil
    var insertTextMode: Int? = nil
    var command: LSPCommand? = nil
    var data: LSPJSONValue? = nil
    private var originalWireValue: LSPJSONValue? = nil

    var wireValue: LSPJSONValue {
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

    init(
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

    enum CodingKeys: String, CodingKey {
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

    init(wireValue: LSPJSONValue) throws {
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

    init(from decoder: Decoder) throws { try self.init(wireValue: LSPJSONValue(from: decoder)) }
    func encode(to encoder: Encoder) throws { try wireValue.encode(to: encoder) }

    func mergingResolved(_ resolved: LSPCompletionItem) throws -> LSPCompletionItem {
        guard case .object(let original) = wireValue, case .object(let changes) = resolved.wireValue else { throw LSPError.invalidPayload }
        return try LSPCompletionItem(wireValue: .object(original.merging(changes) { _, new in new }))
    }
}

struct LSPCompletionResult: Decodable, Sendable {
    let isIncomplete: Bool
    let items: [LSPCompletionItem]

    init(isIncomplete: Bool, items: [LSPCompletionItem]) {
        self.isIncomplete = isIncomplete
        self.items = items
    }

    init(from decoder: Decoder) throws {
        try self.init(wireValue: LSPJSONValue(from: decoder))
    }

    init(wireValue: LSPJSONValue) throws {
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

    enum CodingKeys: String, CodingKey {
        case isIncomplete
        case items
    }
}
