import Foundation

enum SymbolKind: String, Codable, Sendable, CaseIterable {
    case `class`, `struct`, `enum`, interface, module, type
    case function, method, property, constant, macro

    /// Upstream tags capture `@definition.<tag>`.
    init?(tag: String) {
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

    var isType: Bool {
        switch self {
        case .class, .struct, .enum, .interface, .module, .type: true
        case .function, .method, .property, .constant, .macro: false
        }
    }

    var isCallable: Bool { self == .function || self == .method || self == .macro }

    /// Word used in the text sent to the agent.
    var label: String {
        switch self {
        case .interface: "interface"
        default: rawValue
        }
    }

    var badgeLetter: String {
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

struct SymbolEntry: Sendable, Hashable {
    let name: String
    let kind: SymbolKind
    /// Enclosing type, e.g. "SessionManager". Nil at top level.
    let container: String?
    let languageID: String
    let relativePath: String
    /// UTF-16 range of the name in the file.
    let nameRange: NSRange
    /// 0-based, inclusive, full declaration.
    let lineRange: ClosedRange<Int>

    var qualifiedName: String { container.map { "\($0).\(name)" } ?? name }
    /// What the badge and the agent text show: `SessionManager.restore()`.
    var displayName: String { kind.isCallable ? qualifiedName + "()" : qualifiedName }
}
