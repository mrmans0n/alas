import Foundation

public extension HighlightCapture {
    /// Theme token for this capture when no syntax palette applies; nil means
    /// the default foreground.
    var themeToken: String? {
        switch self {
        case .keyword, .attribute, .constant: "syntax-keyword"
        case .type: "syntax-type"
        case .function: "syntax-function"
        case .string: "add"
        case .number: "mod"
        case .comment: "fg-faint"
        case .variable, .parameter, .property, .operator, .punctuation, .plain: nil
        }
    }
}
