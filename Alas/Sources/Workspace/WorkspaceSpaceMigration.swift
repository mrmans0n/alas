import Foundation

enum SpaceMemberReference: Codable, Equatable, Sendable {
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .project:
            self = .project(try container.decode(String.self, forKey: .projectID))
        case .workspace:
            self = .workspace(try container.decode(UUID.self, forKey: .workspaceID))
        }
    }

    func encode(to encoder: Encoder) throws {
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

struct WorkspaceSpaceLayout: Codable, Equatable, Sendable {
    var spaceID: String
    var members: [SpaceMemberReference]
    var legacyProjectIDs: [String]

    init(spaceID: String, members: [SpaceMemberReference], legacyProjectIDs: [String]) {
        self.spaceID = spaceID
        self.members = members
        self.legacyProjectIDs = legacyProjectIDs
    }
}

enum WorkspaceSpaceMigration {
    struct Result: Equatable, Sendable {
        var spaces: [SpaceConfig]
        var layouts: [WorkspaceSpaceLayout]
    }

    static func reupgrade(spacesFile: SpacesFile, savedLayouts: [WorkspaceSpaceLayout]) -> Result {
        let layoutsBySpaceID = Dictionary(uniqueKeysWithValues: savedLayouts.map { ($0.spaceID, $0) })
        var spaces = spacesFile.spaces.map { space -> SpaceConfig in
            var space = space
            let projects = unique(space.projectIds)
            if let members = space.members {
                space.members = uniqueMembers(members)
                space.projectIds = projectIDs(in: space.members ?? [])
            } else if let saved = layoutsBySpaceID[space.id] {
                space.members = merge(saved.members, legacyProjectIDs: projects)
                space.projectIds = projects
            } else {
                space.members = projects.map(SpaceMemberReference.project)
                space.projectIds = projects
            }
            return space
        }

        let currentSpaceIDs = Set(spaces.map(\.id))
        let orphanedWorkspaceMembers = savedLayouts
            .filter { !currentSpaceIDs.contains($0.spaceID) }
            .flatMap(\.members)
            .filter { reference in
                if case .workspace = reference { return true }
                return false
            }
        if !orphanedWorkspaceMembers.isEmpty,
           let activeIndex = spaces.firstIndex(where: { $0.id == spacesFile.activeSpaceId }) {
            let existing = spaces[activeIndex].members ?? []
            spaces[activeIndex].members = uniqueMembers(existing + orphanedWorkspaceMembers)
            spaces[activeIndex].projectIds = projectIDs(in: spaces[activeIndex].members ?? [])
        }

        return Result(
            spaces: spaces,
            layouts: spaces.map {
                WorkspaceSpaceLayout(
                    spaceID: $0.id,
                    members: $0.members ?? $0.projectIds.map(SpaceMemberReference.project),
                    legacyProjectIDs: $0.projectIds
                )
            }
        )
    }

    static func layouts(for spaces: [SpaceConfig]) -> [WorkspaceSpaceLayout] {
        spaces.map {
            WorkspaceSpaceLayout(
                spaceID: $0.id,
                members: $0.members ?? $0.projectIds.map(SpaceMemberReference.project),
                legacyProjectIDs: $0.projectIds
            )
        }
    }

    static func projectIDs(in members: [SpaceMemberReference]) -> [String] {
        unique(members.compactMap { reference in
            guard case .project(let projectID) = reference else { return nil }
            return projectID
        })
    }

    private static func merge(_ savedMembers: [SpaceMemberReference], legacyProjectIDs: [String]) -> [SpaceMemberReference] {
        var remainingProjects = ArraySlice(unique(legacyProjectIDs))
        var result: [SpaceMemberReference] = []
        var lastProjectIndex: Int?

        for member in uniqueMembers(savedMembers) {
            switch member {
            case .project:
                guard let projectID = remainingProjects.popFirst() else { continue }
                result.append(.project(projectID))
                lastProjectIndex = result.index(before: result.endIndex)
            case .workspace:
                result.append(member)
            }
        }

        let appendedProjects = remainingProjects.map(SpaceMemberReference.project)
        if let lastProjectIndex {
            result.insert(contentsOf: appendedProjects, at: result.index(after: lastProjectIndex))
        } else {
            result.append(contentsOf: appendedProjects)
        }
        return uniqueMembers(result)
    }

    private static func unique(_ projectIDs: [String]) -> [String] {
        var seen: Set<String> = []
        return projectIDs.filter { seen.insert($0).inserted }
    }

    private static func uniqueMembers(_ members: [SpaceMemberReference]) -> [SpaceMemberReference] {
        var seenProjects: Set<String> = []
        var seenWorkspaces: Set<UUID> = []
        return members.filter { reference in
            switch reference {
            case .project(let projectID):
                return seenProjects.insert(projectID).inserted
            case .workspace(let workspaceID):
                return seenWorkspaces.insert(workspaceID).inserted
            }
        }
    }
}
