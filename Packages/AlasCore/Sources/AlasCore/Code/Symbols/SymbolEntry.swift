import Foundation

public enum SymbolKind: String, Codable, Sendable, CaseIterable {
    case `class`, `struct`, `enum`, interface, module, type
    case function, method, property, constant, macro

    /// Upstream tags capture `@definition.<tag>`.
    public init?(tag: String) {
        switch tag {
        case "class": self = .class
        case "struct": self = .struct
        case "enum": self = .enum
        case "interface": self = .interface
        case "module": self = .module
        case "type": self = .type
        case "function": self = .function
        case "method": self = .method
        case "property", "field": self = .property
        case "constant": self = .constant
        case "macro": self = .macro
        default: return nil
        }
    }

    public var isType: Bool {
        switch self {
        case .class, .struct, .enum, .interface, .module, .type: true
        case .function, .method, .property, .constant, .macro: false
        }
    }

    public var isCallable: Bool { self == .function || self == .method || self == .macro }

    /// Word used in the text sent to the agent.
    public var label: String {
        switch self {
        case .interface: "interface"
        default: rawValue
        }
    }

    public var badgeLetter: String {
        switch self {
        case .class: "C"
        case .struct: "S"
        case .enum: "E"
        case .interface: "I"
        case .module: "N"
        case .type: "T"
        case .function: "F"
        case .method: "M"
        case .property: "P"
        case .constant: "K"
        case .macro: "X"
        }
    }
}

public struct SymbolEntry: Sendable, Hashable {
    public let name: String
    public let kind: SymbolKind
    /// Enclosing type, e.g. "SessionManager". Nil at top level.
    public let container: String?
    public let languageID: String
    public let relativePath: String
    /// UTF-16 range of the name in the file.
    public let nameRange: NSRange
    /// 0-based, inclusive, full declaration.
    public let lineRange: ClosedRange<Int>

    public var qualifiedName: String { container.map { "\($0).\(name)" } ?? name }
    /// What the badge and the agent text show: `SessionManager.restore()`.
    public var displayName: String { kind.isCallable ? qualifiedName + "()" : qualifiedName }

    public init(name: String, kind: SymbolKind, container: String?, languageID: String, relativePath: String, nameRange: NSRange, lineRange: ClosedRange<Int>) {
        self.name = name
        self.kind = kind
        self.container = container
        self.languageID = languageID
        self.relativePath = relativePath
        self.nameRange = nameRange
        self.lineRange = lineRange
    }
}
