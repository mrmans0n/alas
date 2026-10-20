import Foundation
import AlasFoundation

public struct GeneratedMessage: Equatable, Sendable {
    public let subject: String
    public let body: String

    public init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }
}
