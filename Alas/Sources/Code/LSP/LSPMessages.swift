import Foundation

// MARK: - Envelope

enum LSPID: Hashable, Codable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
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

struct AnyEncodable: Encodable {
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

struct LSPRequest: Encodable {
    let jsonrpc = "2.0"
    let id: LSPID
    let method: String
    let params: AnyEncodable?
}

struct LSPNotification: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: AnyEncodable?
}

struct LSPResponseError: Codable {
    let code: Int
    let message: String
}

struct LSPResponse: Decodable {
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

// Tiny JSON ADT used to round-trip raw `result` payloads
indirect enum JSONValue: Codable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
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

struct LSPPosition: Codable, Hashable {
    let line: Int          // 0-based
    let character: Int     // UTF-16 code units, 0-based per spec
}

struct LSPRange: Codable, Hashable {
    let start: LSPPosition
    let end: LSPPosition
}

struct LSPLocation: Codable, Hashable {
    let uri: String
    let range: LSPRange
}

struct LSPLocationLink: Codable, Hashable {
    let targetUri: String
    let targetRange: LSPRange
    let targetSelectionRange: LSPRange
}

// MARK: - Hover / Definition / Symbols / Diagnostics

struct LSPHoverResult: Decodable {
    let contents: LSPMarkup
    let range: LSPRange?
}

enum LSPMarkup: Decodable {
    case markupContent(kind: String, value: String)
    case plain(String)

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = .plain(s); return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let value = try c.decode(String.self, forKey: .value)
        self = .markupContent(kind: kind, value: value)
    }

    enum CodingKeys: String, CodingKey { case kind, value }
}

struct LSPDocumentSymbol: Decodable {
    let name: String
    let detail: String?
    let kind: Int
    let range: LSPRange
    let selectionRange: LSPRange
    let children: [LSPDocumentSymbol]?
}

struct LSPDiagnostic: Codable, Hashable {
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

struct LSPPublishDiagnosticsParams: Decodable {
    let uri: String
    let diagnostics: [LSPDiagnostic]
}
