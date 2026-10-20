import Foundation

public struct ACPCursorTodo: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let content: String
    public let status: String

    public init(id: String, content: String, status: String) {
        self.id = id
        self.content = content
        self.status = status
    }
}
