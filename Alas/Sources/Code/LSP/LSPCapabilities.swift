import Foundation

enum EditorCommandID: String, CaseIterable, Sendable {
    case definition
    case typeDefinition
    case implementation
    case references
    case rename
    case codeActions
    case formatSelection
    case formatDocument
    case hover
    case signatureHelp
    case back
    case forward
    case nextProblem
    case previousProblem
    case toggleInlayHints
}

/// Immutable server capability snapshot captured from `initialize`.
struct LSPCapabilities: Equatable, Sendable {
    private let supportedCommands: Set<EditorCommandID>
    private(set) var semanticTokens: SemanticTokensProvider?

    struct SemanticTokensProvider: Equatable, Sendable, Decodable {
        struct Legend: Equatable, Sendable, Decodable {
            let tokenTypes: [String]
            let tokenModifiers: [String]
        }
        let legend: Legend
        let supportsRange: Bool
        let supportsFull: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            legend = try container.decode(Legend.self, forKey: .legend)
            supportsRange = try container.decodeIfPresent(Provider.self, forKey: .range)?.isSupported ?? false
            supportsFull = try container.decodeIfPresent(Provider.self, forKey: .full)?.isSupported ?? false
        }

        private enum CodingKeys: String, CodingKey { case legend, range, full }
    }

    static let empty = LSPCapabilities(supportedCommands: [])

    init(supportedCommands: Set<EditorCommandID>) {
        self.supportedCommands = supportedCommands
    }

    init(json: Data) throws {
        let providers = try JSONDecoder().decode(Providers.self, from: json)
        self.init(providers: providers)
    }

    static func fromInitializeResult(_ json: Data?) -> LSPCapabilities {
        guard let json,
              let result = try? JSONDecoder().decode(InitializeResult.self, from: json)
        else {
            return .empty
        }
        return LSPCapabilities(providers: result.capabilities)
    }

    func supports(_ command: EditorCommandID) -> Bool {
        supportedCommands.contains(command)
    }

    private init(providers: Providers) {
        var commands: Set<EditorCommandID> = []
        if providers.definitionProvider?.isSupported == true { commands.insert(.definition) }
        if providers.typeDefinitionProvider?.isSupported == true { commands.insert(.typeDefinition) }
        if providers.implementationProvider?.isSupported == true { commands.insert(.implementation) }
        if providers.referencesProvider?.isSupported == true { commands.insert(.references) }
        if providers.renameProvider?.isSupported == true { commands.insert(.rename) }
        if providers.codeActionProvider?.isSupported == true { commands.insert(.codeActions) }
        if providers.documentRangeFormattingProvider?.isSupported == true { commands.insert(.formatSelection) }
        if providers.documentFormattingProvider?.isSupported == true { commands.insert(.formatDocument) }
        if providers.hoverProvider?.isSupported == true { commands.insert(.hover) }
        if providers.signatureHelpProvider?.isSupported == true { commands.insert(.signatureHelp) }
        if providers.inlayHintProvider?.isSupported == true { commands.insert(.toggleInlayHints) }
        self.init(supportedCommands: commands)
        semanticTokens = providers.semanticTokensProvider
    }

    private struct InitializeResult: Decodable {
        let capabilities: Providers
    }

    private struct Providers: Decodable {
        let hoverProvider: Provider?
        let signatureHelpProvider: Provider?
        let definitionProvider: Provider?
        let typeDefinitionProvider: Provider?
        let implementationProvider: Provider?
        let referencesProvider: Provider?
        let renameProvider: Provider?
        let codeActionProvider: Provider?
        let documentRangeFormattingProvider: Provider?
        let documentFormattingProvider: Provider?
        let inlayHintProvider: Provider?
        let semanticTokensProvider: SemanticTokensProvider?
    }

    private enum Provider: Decodable {
        case unsupported
        case supported

        var isSupported: Bool {
            switch self {
            case .unsupported: false
            case .supported: true
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) {
                self = value ? .supported : .unsupported
                return
            }
            _ = try decoder.container(keyedBy: EmptyCodingKeys.self)
            self = .supported
        }

        private enum EmptyCodingKeys: CodingKey {}
    }
}
