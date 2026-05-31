import Foundation
import Observation

@Observable
@MainActor
final class SpacesManager {
    private(set) var spaces: [SpaceConfig]
    private(set) var activeSpaceId: String

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
                normalized.projectIds = Self.unique(normalized.projectIds)
                return normalized
            }

        self.spaces = normalizedSpaces
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
        SpacesFile(activeSpaceId: activeSpaceId, spaces: spaces)
    }

    var activeSpace: SpaceConfig? {
        space(id: activeSpaceId)
    }

    var shouldShowSpaceAffordance: Bool {
        guard spaces.count == 1, let only = spaces.first else { return true }
        return only.name != SpaceConfig.defaultName || only.emoji != SpaceConfig.defaultEmoji
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
            emoji: emoji,
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
        spaces[index].emoji = emoji
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
        spaces[index].projectIds.append(projectId)
    }

    @discardableResult
    func removeProject(_ projectId: String, fromSpace spaceId: String) -> Bool {
        guard membershipCount(forProject: projectId) > 1,
              let index = spaces.firstIndex(where: { $0.id == spaceId }),
              spaces[index].projectIds.contains(projectId)
        else { return false }

        spaces[index].projectIds.removeAll { $0 == projectId }
        return true
    }

    func removeProjectEverywhere(_ projectId: String) {
        for index in spaces.indices {
            spaces[index].projectIds.removeAll { $0 == projectId }
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

        let moving = spaces[spaceIndex].projectIds.remove(at: fromIndex)
        let clampedDestination = min(toIndex, spaces[spaceIndex].projectIds.count)
        spaces[spaceIndex].projectIds.insert(moving, at: clampedDestination)
    }

    func moveProjectToEndInActiveSpace(id: String) {
        guard let spaceIndex = spaces.firstIndex(where: { $0.id == activeSpaceId }),
              let fromIndex = spaces[spaceIndex].projectIds.firstIndex(of: id),
              fromIndex != spaces[spaceIndex].projectIds.count - 1
        else { return }

        let moving = spaces[spaceIndex].projectIds.remove(at: fromIndex)
        spaces[spaceIndex].projectIds.append(moving)
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
            let pruned = spaces[index].projectIds.filter { validProjectIds.contains($0) }
            if pruned != spaces[index].projectIds {
                spaces[index].projectIds = pruned
                changed = true
            }
        }
        return changed
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SpaceConfig.defaultName : trimmed
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
