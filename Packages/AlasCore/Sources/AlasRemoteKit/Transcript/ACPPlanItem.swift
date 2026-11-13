import Foundation

public struct ACPPlanItem: Codable, Equatable, Hashable, Sendable {
    public let content: String
    public var status: String   // "pending" | "in_progress" | "completed"

    public init(content: String, status: String) {
        self.content = content
        self.status = status
    }
}
