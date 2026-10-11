import Foundation

public enum MermaidFence: Sendable {
    public static func isMermaid(language: String?) -> Bool {
        language?
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased() == "mermaid"
    }
}
