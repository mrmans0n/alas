import Foundation
import Observation

@Observable
@MainActor
final class SpacesManager {
    private(set) var spaces: [SpaceConfig]
    private(set) var activeSpaceId: String
    private(set) var showSingleSpaceAffordance: Bool

    private var recentlyActiveSpaceIds: [String] = []

    init(file: SpacesFile) {
        let normalizedSpaces = file.spaces.isEmpty
            ? [
                SpaceConfig(
                    id: UUID().uuidString,
                    name: SpaceConfig.defaultName,
                    emoji: SpaceConfig.defaultEmoji,
                    projectIds: [],
                    lastSelectedWorktreeId: nil,
                    createdAt: Date()
                )
            ]
            : file.spaces.map { space in
                var normalized = space
                normalized.name = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let members = normalized.members {
                    normalized.members = Self.uniqueMembers(members)
                    normalized.projectIds = WorkspaceSpaceMigration.projectIDs(in: normalized.members ?? [])
                } else {
                    normalized.projectIds = Self.unique(normalized.projectIds)
                }
                return normalized
            }

        self.spaces = normalizedSpaces
        self.showSingleSpaceAffordance = file.showSingleSpaceAffordance
        if normalizedSpaces.contains(where: { $0.id == file.activeSpaceId }) {
            activeSpaceId = file.activeSpaceId
        } else {
            activeSpaceId = normalizedSpaces[0].id
        }
    }

    static func migrating(projects: [ProjectConfig], now: Date = Date()) -> SpacesManager {
        let space = SpaceConfig(
            id: UUID().uuidString,
            name: SpaceConfig.defaultName,
            emoji: SpaceConfig.defaultEmoji,
            projectIds: projects.map(\.id),
            lastSelectedWorktreeId: nil,
            createdAt: now
        )
        return SpacesManager(file: SpacesFile(activeSpaceId: space.id, spaces: [space]))
    }

    var file: SpacesFile {
        SpacesFile(activeSpaceId: activeSpaceId, spaces: spaces, showSingleSpaceAffordance: showSingleSpaceAffordance)
    }

    var activeSpace: SpaceConfig? {
        space(id: activeSpaceId)
    }

    var shouldShowSpaceAffordance: Bool {
        spaces.count > 1 || showSingleSpaceAffordance
    }

    func space(id: String) -> SpaceConfig? {
        spaces.first { $0.id == id }
    }

    func activeProjects(from projects: [ProjectConfig]) -> [ProjectConfig] {
        guard let activeSpace else { return [] }
        let projectsById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        return activeSpace.projectIds.compactMap { projectsById[$0] }
    }

    func addSpace(name: String, emoji: String, now: Date = Date()) -> String {
        let id = UUID().uuidString
        let space = SpaceConfig(
            id: id,
            name: normalizedName(name),
            emoji: SpaceIcon.sanitized(emoji),
            projectIds: [],
            lastSelectedWorktreeId: nil,
            createdAt: now
        )
        spaces.append(space)
        return id
    }

    func renameSpace(id: String, name: String) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = normalizedName(name)
    }

    func setEmoji(spaceId: String, emoji: String) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceId }) else { return }
        spaces[index].emoji = SpaceIcon.sanitized(emoji, fallback: spaces[index].emoji)
    }

    func setShowSingleSpaceAffordance(_ show: Bool) {
        showSingleSpaceAffordance = show
    }

    func switchToSpace(id: String) {
        guard id != activeSpaceId, spaces.contains(where: { $0.id == id }) else { return }
        recentlyActiveSpaceIds.removeAll { $0 == activeSpaceId || $0 == id }
        recentlyActiveSpaceIds.insert(activeSpaceId, at: 0)
        activeSpaceId = id
    }

    func containingSpaceId(forProjectId projectId: String) -> String? {
        if activeSpace?.projectIds.contains(projectId) == true {
            return activeSpaceId
        }

        if let recent = recentlyActiveSpaceIds.first(where: { id in
            space(id: id)?.projectIds.contains(projectId) == true
        }) {
            return recent
        }

        return spaces.first { $0.projectIds.contains(projectId) }?.id
    }

    func addProject(_ projectId: String, toSpace spaceId: String) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceId }),
              !spaces[index].projectIds.contains(projectId)
        else { return }
        if var members = spaces[index].members {
            members.append(.project(projectId))
            setMembers(members, at: index)
        } else {
            spaces[index].projectIds.append(projectId)
        }
    }

    @discardableResult
    func removeProject(_ projectId: String, fromSpace spaceId: String) -> Bool {
        guard membershipCount(forProject: projectId) > 1,
              let index = spaces.firstIndex(where: { $0.id == spaceId }),
              spaces[index].projectIds.contains(projectId)
        else { return false }

        if let members = spaces[index].members {
            setMembers(members.filter { $0 != .project(projectId) }, at: index)
        } else {
            spaces[index].projectIds.removeAll { $0 == projectId }
        }
        return true
    }

    func removeProjectEverywhere(_ projectId: String) {
        for index in spaces.indices {
            if let members = spaces[index].members {
                setMembers(members.filter { $0 != .project(projectId) }, at: index)
            } else {
                spaces[index].projectIds.removeAll { $0 == projectId }
            }
        }
    }

    func membershipCount(forProject projectId: String) -> Int {
        spaces.reduce(0) { count, space in
            count + (space.projectIds.contains(projectId) ? 1 : 0)
        }
    }

    func setLastSelectedWorktree(_ worktreeId: String?, forSpace spaceId: String? = nil) {
        let targetId = spaceId ?? activeSpaceId
        guard let index = spaces.firstIndex(where: { $0.id == targetId }) else { return }
        spaces[index].lastSelectedWorktreeId = worktreeId
    }

    func reorderProjectInActiveSpace(movingId: String, destinationId: String) {
        guard let spaceIndex = spaces.firstIndex(where: { $0.id == activeSpaceId }),
              let fromIndex = spaces[spaceIndex].projectIds.firstIndex(of: movingId),
              let toIndex = spaces[spaceIndex].projectIds.firstIndex(of: destinationId),
              fromIndex != toIndex
        else { return }

        if var members = spaces[spaceIndex].members,
           let memberFromIndex = members.firstIndex(of: .project(movingId)),
           let memberToIndex = members.firstIndex(of: .project(destinationId)) {
            let moving = members.remove(at: memberFromIndex)
            members.insert(moving, at: min(memberToIndex, members.count))
            setMembers(members, at: spaceIndex)
        } else {
            let moving = spaces[spaceIndex].projectIds.remove(at: fromIndex)
            let clampedDestination = min(toIndex, spaces[spaceIndex].projectIds.count)
            spaces[spaceIndex].projectIds.insert(moving, at: clampedDestination)
        }
    }

    func moveProjectToEndInActiveSpace(id: String) {
        guard let spaceIndex = spaces.firstIndex(where: { $0.id == activeSpaceId }),
              let fromIndex = spaces[spaceIndex].projectIds.firstIndex(of: id),
              fromIndex != spaces[spaceIndex].projectIds.count - 1
        else { return }

        if var members = spaces[spaceIndex].members,
           let memberFromIndex = members.firstIndex(of: .project(id)) {
            let moving = members.remove(at: memberFromIndex)
            members.append(moving)
            setMembers(members, at: spaceIndex)
        } else {
            let moving = spaces[spaceIndex].projectIds.remove(at: fromIndex)
            spaces[spaceIndex].projectIds.append(moving)
        }
    }

    @discardableResult
    func deleteSpace(id: String) -> Bool {
        guard spaces.count > 1,
              let index = spaces.firstIndex(where: { $0.id == id })
        else { return false }

        let replacementIndex: Int
        if index == spaces.count - 1 {
            replacementIndex = index - 1
        } else {
            replacementIndex = index + 1
        }

        let deletedProjectIds = spaces[index].projectIds
        for projectId in deletedProjectIds where membershipCount(forProject: projectId) == 1 {
            addProject(projectId, toSpace: spaces[replacementIndex].id)
        }

        // Workspace references are intentionally retained even when the
        // Workspace record is not currently available. Their lifecycle is
        // independent from the Project-only Spaces manager.
        if let members = spaces[index].members {
            let workspaces = members.filter {
                if case .workspace = $0 { return true }
                return false
            }
            if !workspaces.isEmpty {
                let replacementMembers = (spaces[replacementIndex].members ?? spaces[replacementIndex].projectIds.map(SpaceMemberReference.project)) + workspaces
                setMembers(replacementMembers, at: replacementIndex)
            }
        }

        let replacementId = spaces[replacementIndex].id
        spaces.remove(at: index)
        recentlyActiveSpaceIds.removeAll { $0 == id }
        if activeSpaceId == id {
            activeSpaceId = replacementId
        }
        return true
    }

    @discardableResult
    func pruneMissingProjects(validProjectIds: Set<String>) -> Bool {
        var changed = false
        for index in spaces.indices {
            if let members = spaces[index].members {
                let pruned = members.filter { reference in
                    guard case .project(let projectID) = reference else { return true }
                    return validProjectIds.contains(projectID)
                }
                if pruned != members {
                    setMembers(pruned, at: index)
                    changed = true
                }
            } else {
                let pruned = spaces[index].projectIds.filter { validProjectIds.contains($0) }
                if pruned != spaces[index].projectIds {
                    spaces[index].projectIds = pruned
                    changed = true
                }
            }
        }
        return changed
    }

    func setTypedMembers(_ members: [SpaceMemberReference], forSpace spaceID: String) {
        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        setMembers(members, at: index)
    }

    func replace(file: SpacesFile) {
        let replacement = SpacesManager(file: file)
        spaces = replacement.spaces
        activeSpaceId = replacement.activeSpaceId
        showSingleSpaceAffordance = replacement.showSingleSpaceAffordance
        recentlyActiveSpaceIds.removeAll { id in !spaces.contains(where: { $0.id == id }) }
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SpaceConfig.defaultName : trimmed
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }

    private func setMembers(_ members: [SpaceMemberReference], at index: Int) {
        let uniqueMembers = Self.uniqueMembers(members)
        spaces[index].members = uniqueMembers
        spaces[index].projectIds = WorkspaceSpaceMigration.projectIDs(in: uniqueMembers)
    }

    private static func uniqueMembers(_ members: [SpaceMemberReference]) -> [SpaceMemberReference] {
        var seenProjects: Set<String> = []
        var seenWorkspaces: Set<UUID> = []
        return members.filter { member in
            switch member {
            case .project(let projectID):
                return seenProjects.insert(projectID).inserted
            case .workspace(let workspaceID):
                return seenWorkspaces.insert(workspaceID).inserted
            }
        }
    }
}
