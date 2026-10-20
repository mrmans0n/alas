import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

/// A simplified syntax-highlight category derived from a tree-sitter
/// capture name (e.g. "keyword.control" -> .keyword).
public enum HighlightCapture: String, Sendable {
    case keyword, type, function, string, number, comment, attribute
    case constant, variable, parameter, property, `operator`, punctuation
    case plain   // sentinel for "no capture"

    public static func fromSemanticToken(_ type: String, readonly: Bool = false) -> HighlightCapture? {
        switch type {
        case "namespace", "type", "class", "enum", "interface", "struct", "typeParameter": return .type
        case "function", "method", "macro": return .function
        case "enumMember": return .constant
        case "decorator": return .attribute
        case "regexp": return .string
        case "variable" where readonly, "property" where readonly: return .constant
        default: return HighlightCapture(rawValue: type).flatMap { $0 == .plain ? nil : $0 }
        }
    }

    public static func from(name: String) -> HighlightCapture {
        // Tree-sitter highlight names use dotted forms ("keyword.control",
        // "function.method"). Take the first dot-separated segment and map.
        let head = name.split(separator: ".").first.map(String.init) ?? name
        switch head {
        case "tag", "conditional", "repeat", "preproc":
            return .keyword
        case "text":
            return .string
        case "method", "constructor":
            return .function
        case "boolean":
            return .constant
        case "field":
            return .property
        default:
            break
        }
        return HighlightCapture(rawValue: head) ?? .plain
    }
}

public struct HighlightSpan: Equatable, Sendable {
    public let range: NSRange
    public let capture: HighlightCapture

    public init(range: NSRange, capture: HighlightCapture) {
        self.range = range
        self.capture = capture
    }
}
