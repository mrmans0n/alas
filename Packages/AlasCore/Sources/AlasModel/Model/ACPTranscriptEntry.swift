import Foundation
import AlasFoundation

public struct ACPTranscriptEntry: Codable, Equatable, Sendable {
    public let index: Int
    public let role: String
    public let text: String
    /// True when `text` was cut to fit the character budget; omitted
    /// from the wire otherwise.
    public var truncated: Bool? = nil

    public init(index: Int, role: String, text: String, truncated: Bool? = nil) {
        self.index = index
        self.role = role
        self.text = text
        self.truncated = truncated
    }
}
