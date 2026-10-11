import Foundation

enum MermaidFence {
    static func isMermaid(language: String?) -> Bool {
        language?
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased() == "mermaid"
    }
}
