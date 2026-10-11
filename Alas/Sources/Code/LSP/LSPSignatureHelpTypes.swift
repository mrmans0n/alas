import Foundation

struct LSPSignatureHelp: Codable, Equatable, Hashable, Sendable {
    let signatures: [LSPSignatureInformation]
    let activeSignature: Int?
    let activeParameter: Int?
}

struct LSPSignatureHelpContext: Codable, Hashable, Sendable {
    let triggerKind: LSPSignatureHelpTriggerKind
    let triggerCharacter: String?
    let isRetrigger: Bool
    let activeSignatureHelp: LSPSignatureHelp?

    init(
        triggerKind: LSPSignatureHelpTriggerKind,
        triggerCharacter: String?,
        isRetrigger: Bool,
        activeSignatureHelp: LSPSignatureHelp?
    ) {
        self.triggerKind = triggerKind
        self.triggerCharacter = triggerCharacter
        self.isRetrigger = isRetrigger
        self.activeSignatureHelp = activeSignatureHelp
    }

    private enum CodingKeys: String, CodingKey {
        case triggerKind, triggerCharacter, isRetrigger, activeSignatureHelp
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(triggerKind, forKey: .triggerKind)
        try container.encodeIfPresent(triggerCharacter, forKey: .triggerCharacter)
        try container.encode(isRetrigger, forKey: .isRetrigger)
        try container.encodeIfPresent(activeSignatureHelp, forKey: .activeSignatureHelp)
    }
}

struct LSPSignatureHelpParams: Codable, Hashable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let position: LSPPosition
    let context: LSPSignatureHelpContext?
}

struct LSPSignatureInformation: Codable, Equatable, Hashable, Sendable {
    let label: String
    let documentation: LSPSignatureDocumentation?
    let parameters: [LSPSignatureParameter]?
    let activeParameter: Int?
}

enum LSPSignatureHelpTriggerKind: Int, Codable, Hashable, Sendable {
    case invoked = 1
    case triggerCharacter = 2
    case contentChange = 3
}

enum LSPSignatureDocumentation: Codable, Equatable, Hashable, Sendable {
    case plain(String)
    case markup(kind: String, value: String)

    var displayText: String {
        switch self {
        case .plain(let value), .markup(_, let value): value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .plain(value)
            return
        }
        let markup = try container.decode(Markup.self)
        self = .markup(kind: markup.kind, value: markup.value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let value):
            try container.encode(value)
        case .markup(let kind, let value):
            try container.encode(Markup(kind: kind, value: value))
        }
    }

    private struct Markup: Codable, Equatable, Hashable, Sendable {
        let kind: String
        let value: String
    }
}

enum LSPSignatureParameterLabel: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case offsets(start: Int, end: Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        let values = try container.decode([Int].self)
        guard values.count == 2 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "parameter label offsets require exactly two values")
        }
        self = .offsets(start: values[0], end: values[1])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .offsets(let start, let end):
            try container.encode([start, end])
        }
    }
}

struct LSPSignatureParameter: Codable, Equatable, Hashable, Sendable {
    let label: LSPSignatureParameterLabel
    let documentation: LSPSignatureDocumentation?
}
