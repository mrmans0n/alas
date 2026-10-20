import Foundation
import AlasFoundation

public struct DiffReviewFileID: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let namespace: String
    public let path: String

    public var id: String { rawValue }
    public var rawValue: String { "\(namespace):\(path)" }

    public init(namespace: String, path: String) {
        self.namespace = namespace
        self.path = path
    }
}
