import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

public enum MermaidFence: Sendable {
    public static func isMermaid(language: String?) -> Bool {
        language?
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased() == "mermaid"
    }
}
