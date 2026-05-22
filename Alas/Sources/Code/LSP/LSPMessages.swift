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
                    case .plain(let p):            pieces.append(p)
                    case .markupContent(_, let v): pieces.append(v)
                    }
                } else {
                    _ = try? arr.decode(JSONValue.self)  // skip unknown
                }
            }
            self = .plain(pieces.joined(separator: "\n\n"))
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
    let range: LSPRange
    let severity: Int?       // 1=error 2=warning 3=info 4=hint
    let code: String?
    let source: String?
    let message: String

    enum CodingKeys: String, CodingKey { case range, severity, code, source, message }
    init(from decoder: Decoder) throws {
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
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(range, forKey: .range)
        try c.encodeIfPresent(severity, forKey: .severity)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(message, forKey: .message)
    }
}

struct LSPPublishDiagnosticsParams: Decodable, Sendable {
    let uri: String
    let diagnostics: [LSPDiagnostic]
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
}
