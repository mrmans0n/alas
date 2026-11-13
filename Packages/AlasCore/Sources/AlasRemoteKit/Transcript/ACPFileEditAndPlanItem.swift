import Foundation

public struct ACPFileEdit: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public var added: Int
    public var removed: Int
    public var oldText: String?
    public var newText: String

    public init(path: String, added: Int, removed: Int, oldText: String? = nil, newText: String = "") {
        self.path = path
        self.added = added
        self.removed = removed
        self.oldText = oldText
        self.newText = newText
    }

    private enum CodingKeys: String, CodingKey {
        case path, added, removed, oldText, newText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        added = try c.decode(Int.self, forKey: .added)
        removed = try c.decode(Int.self, forKey: .removed)
        oldText = try c.decodeIfPresent(String.self, forKey: .oldText)
        newText = try c.decodeIfPresent(String.self, forKey: .newText) ?? ""
    }
}

public struct ACPPlanItem: Codable, Equatable, Hashable, Sendable {
    public let content: String
    public var status: String   // "pending" | "in_progress" | "completed"

    public init(content: String, status: String) {
        self.content = content
        self.status = status
    }
}