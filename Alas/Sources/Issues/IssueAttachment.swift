import Foundation

struct IssueAttachment: Codable, Equatable, Sendable {
    let canonicalURL: URL
    let providerLabel: String
    let displayReference: String?
    let title: String

    var displayTitle: String {
        [displayReference, title.isEmpty ? nil : title]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
