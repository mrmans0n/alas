import Foundation

public struct LSPSignatureHelp: Codable, Equatable, Hashable, Sendable {
    public let signatures: [LSPSignatureInformation]
    public let activeSignature: Int?
    public let activeParameter: Int?

    public init(signatures: [LSPSignatureInformation], activeSignature: Int?, activeParameter: Int?) {
        self.signatures = signatures
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
    }
}

public struct LSPSignatureHelpContext: Codable, Hashable, Sendable {
    public let triggerKind: LSPSignatureHelpTriggerKind
    public let triggerCharacter: String?
    public let isRetrigger: Bool
    public let activeSignatureHelp: LSPSignatureHelp?

    public init(
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(triggerKind, forKey: .triggerKind)
        try container.encodeIfPresent(triggerCharacter, forKey: .triggerCharacter)
        try container.encode(isRetrigger, forKey: .isRetrigger)
        try container.encodeIfPresent(activeSignatureHelp, forKey: .activeSignatureHelp)
    }
}

public struct LSPSignatureHelpParams: Codable, Hashable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let position: LSPPosition
    public let context: LSPSignatureHelpContext?

    public init(textDocument: LSPTextDocumentIdentifier, position: LSPPosition, context: LSPSignatureHelpContext?) {
        self.textDocument = textDocument
        self.position = position
        self.context = context
    }
}

public struct LSPSignatureInformation: Codable, Equatable, Hashable, Sendable {
    public let label: String
    public let documentation: LSPSignatureDocumentation?
    public let parameters: [LSPSignatureParameter]?
    public let activeParameter: Int?

    public init(label: String, documentation: LSPSignatureDocumentation?, parameters: [LSPSignatureParameter]?, activeParameter: Int?) {
        self.label = label
        self.documentation = documentation
        self.parameters = parameters
        self.activeParameter = activeParameter
    }
}

public enum LSPSignatureHelpTriggerKind: Int, Codable, Hashable, Sendable {
    case invoked = 1
    case triggerCharacter = 2
    case contentChange = 3
}

public enum LSPSignatureDocumentation: Codable, Equatable, Hashable, Sendable {
    case plain(String)
    case markup(kind: String, value: String)

    public var displayText: String {
        switch self {
        case .plain(let value), .markup(_, let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .plain(value)
            return
        }
        let markup = try container.decode(Markup.self)
        self = .markup(kind: markup.kind, value: markup.value)
    }

    public func encode(to encoder: Encoder) throws {
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

        public init(kind: String, value: String) {
            self.kind = kind
            self.value = value
        }
    }
}

public enum LSPSignatureParameterLabel: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case offsets(start: Int, end: Int)

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .offsets(let start, let end):
            try container.encode([start, end])
        }
    }
}

public struct LSPSignatureParameter: Codable, Equatable, Hashable, Sendable {
    public let label: LSPSignatureParameterLabel
    public let documentation: LSPSignatureDocumentation?

    public init(label: LSPSignatureParameterLabel, documentation: LSPSignatureDocumentation?) {
        self.label = label
        self.documentation = documentation
    }
}
