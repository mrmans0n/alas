import Foundation
import AlasFoundation

public struct IssueAttachment: Codable, Equatable, Sendable {
    public let canonicalURL: URL
    public let providerLabel: String
    public let displayReference: String?
    public let title: String

    public var displayTitle: String {
        [displayReference, title.isEmpty ? nil : title]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    public init(canonicalURL: URL, providerLabel: String, displayReference: String?, title: String) {
        self.canonicalURL = canonicalURL
        self.providerLabel = providerLabel
        self.displayReference = displayReference
        self.title = title
    }
}
