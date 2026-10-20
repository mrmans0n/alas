import Foundation

public enum SpaceMemberReference: Codable, Equatable, Sendable {
    case project(String)
    case workspace(UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case projectID
        case workspaceID
    }

    private enum Kind: String, Codable {
        case project
        case workspace
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .project:
            self = .project(try container.decode(String.self, forKey: .projectID))
        case .workspace:
            self = .workspace(try container.decode(UUID.self, forKey: .workspaceID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .project(let projectID):
            try container.encode(Kind.project, forKey: .kind)
            try container.encode(projectID, forKey: .projectID)
        case .workspace(let workspaceID):
            try container.encode(Kind.workspace, forKey: .kind)
            try container.encode(workspaceID, forKey: .workspaceID)
        }
    }
}
