import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct AppStateSpacesTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        var projectsFile: ProjectsFile = ProjectsFile(projects: [])
        var spacesFile: SpacesFile?
        var writes: ((Any, URL) -> Void)?

        func write<T: Encodable>(_ value: T, to url: URL) throws {
            writes?(value, url)
        }

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            if type == ProjectsFile.self { return projectsFile as? T }
            if type == SpacesFile.self { return spacesFile as? T }
            if type == AppConfig.self { return AppConfig.defaults as? T }
            return nil
        }
    }

    private func project(_ id: String) -> ProjectConfig {
        ProjectConfig(id: id, name: id, path: "/tmp/\(id)", color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0))
    }

    private func project(_ id: String, path: String) -> ProjectConfig {
        ProjectConfig(id: id, name: id, path: path, color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0))
    }

    private func worktree(_ id: String, projectId: String) -> Worktree {
        Worktree(
            id: id,
            projectId: projectId,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/\(projectId)"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-spaces-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "t"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    private func waitForOperationToClear(
        _ manager: ProjectsManager,
        id: String,
        timeoutSeconds: Double = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if manager.operationState(for: id) == nil { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Timed out waiting for operationState to clear for id \(id)")
    }

    @Test func migratesSpacesWhenMissingSpacesFile() {
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project("p1"), project("p2")])))

        #expect(state.spacesManager.spaces.count == 1)
        #expect(state.activeSpaceProjects.map(\.id) == ["p1", "p2"])
        #expect(!state.spacesManager.shouldShowSpaceAffordance)
    }

    @Test func activeSpaceProjectsUseSpaceMembershipOrder() {
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p2"], lastSelectedWorktreeId: nil, createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project("p1"), project("p2")]), spacesFile: spaces))

        #expect(state.activeSpaceProjects.map(\.id) == ["p2"])
        #expect(state.projects.map(\.id) == ["p1", "p2"])
    }

    @Test func initAddsOrphanProjectsToActiveSpace() {
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project("p1"), project("p2")]), spacesFile: spaces))

        #expect(state.activeSpaceProjects.map(\.id) == ["p1", "p2"])
        #expect(state.spacesManager.activeSpace?.projectIds == ["p1", "p2"])
    }

    @Test func selectingWorktreeStoresLastSelectionForActiveSpace() {
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project("p1")])))

        state.selectWorktree(id: "wt1")

        #expect(state.selectedWorktreeId == "wt1")
        #expect(state.spacesManager.activeSpace?.lastSelectedWorktreeId == "wt1")
    }

    @Test func selectingWorktreeDefersAndCoalescesSpacePersistence() async throws {
        var spaceWriteCount = 0
        var persistedSelection: String?
        let state = AppState(store: MemoryStore(
            projectsFile: ProjectsFile(projects: [project("p1")]),
            writes: { value, url in
                guard url == Paths.spacesFile else { return }
                spaceWriteCount += 1
                persistedSelection = (value as? SpacesFile)?
                    .spaces
                    .first?
                    .lastSelectedWorktreeId
            }
        ))

        state.selectWorktree(id: "wt1")
        state.selectWorktree(id: "wt2")

        #expect(state.selectedWorktreeId == "wt2")
        #expect(state.spacesManager.activeSpace?.lastSelectedWorktreeId == "wt2")
        #expect(spaceWriteCount == 0)

        try await Task.sleep(nanoseconds: 350_000_000)

        #expect(spaceWriteCount == 1)
        #expect(persistedSelection == "wt2")
    }

    @Test func flushScheduledSpacesSavePersistsPendingSelectionImmediately() {
        var spaceWriteCount = 0
        var persistedSelection: String?
        let state = AppState(store: MemoryStore(
            projectsFile: ProjectsFile(projects: [project("p1")]),
            writes: { value, url in
                guard url == Paths.spacesFile else { return }
                spaceWriteCount += 1
                persistedSelection = (value as? SpacesFile)?
                    .spaces
                    .first?
                    .lastSelectedWorktreeId
            }
        ))

        state.selectWorktree(id: "wt1")
        #expect(spaceWriteCount == 0)

        state.flushScheduledSpacesSave()

        #expect(spaceWriteCount == 1)
        #expect(persistedSelection == "wt1")
    }

    @Test func startupSelectionUsesRememberedActiveSpaceWorktreeBeforeFirstVisible() {
        let p1 = project("p1")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: "wt2", createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1]), spacesFile: spaces))
        state.projectsManager.insertOptimisticWorktree(worktree("wt1", projectId: "p1"))
        state.projectsManager.insertOptimisticWorktree(worktree("wt2", projectId: "p1"))

        #expect(state.resolvedSelectionForActiveSpaceForStartup() == "wt2")
    }

    @Test func switchingSpacesRestoresLastSelectionThenFallback() {
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: "wt1", createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: "wt2", createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))
        state.projectsManager.insertOptimisticWorktree(worktree("wt1", projectId: "p1"))
        state.projectsManager.insertOptimisticWorktree(worktree("wt2", projectId: "p2"))

        state.switchToSpace(id: "s2")

        #expect(state.spacesManager.activeSpaceId == "s2")
        #expect(state.selectedWorktreeId == "wt2")
    }

    @Test func switchingToAdjacentSpaceReturnsFalseWithSingleSpace() {
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project("p1")])))
        let activeSpaceId = state.spacesManager.activeSpaceId

        let changed = state.switchToAdjacentSpace(offset: 1)

        #expect(!changed)
        #expect(state.spacesManager.activeSpaceId == activeSpaceId)
    }

    @Test func switchingToAdjacentSpaceReturnsTrueAndChangesActiveSpace() {
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))

        let changed = state.switchToAdjacentSpace(offset: 1)

        #expect(changed)
        #expect(state.spacesManager.activeSpaceId == "s2")
    }

    @Test func switchingToSpaceByNumberNoOpsWhenMissing() {
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project("p1")])))
        let activeSpaceId = state.spacesManager.activeSpaceId

        let changed = state.switchToSpace(atOneBasedIndex: 2)

        #expect(!changed)
        #expect(state.spacesManager.activeSpaceId == activeSpaceId)
    }

    @Test func deletingActiveSpaceSelectsFallbackAndPersistsOnce() {
        var spaceWriteCount = 0
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s2",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: "wt1", createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: "wt2", createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(
            projectsFile: ProjectsFile(projects: [p1, p2]),
            spacesFile: spaces,
            writes: { _, url in
                if url == Paths.spacesFile {
                    spaceWriteCount += 1
                }
            }
        ))
        state.projectsManager.insertOptimisticWorktree(worktree("wt1", projectId: "p1"))
        state.projectsManager.insertOptimisticWorktree(worktree("wt2", projectId: "p2"))
        state.selectedWorktreeId = "wt2"
        spaceWriteCount = 0

        state.deleteSpace(id: "s2")

        #expect(state.spacesManager.activeSpaceId == "s1")
        #expect(state.selectedWorktreeId == "wt1")
        #expect(state.spacesManager.activeSpace?.lastSelectedWorktreeId == "wt1")
        #expect(spaceWriteCount == 1)
    }

    @Test func deletingInactiveSpacePersistsOnceWithoutChangingSelection() {
        var spaceWriteCount = 0
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: "wt1", createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: "wt2", createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(
            projectsFile: ProjectsFile(projects: [p1, p2]),
            spacesFile: spaces,
            writes: { _, url in
                if url == Paths.spacesFile {
                    spaceWriteCount += 1
                }
            }
        ))
        state.projectsManager.insertOptimisticWorktree(worktree("wt1", projectId: "p1"))
        state.projectsManager.insertOptimisticWorktree(worktree("wt2", projectId: "p2"))
        state.selectedWorktreeId = "wt1"
        spaceWriteCount = 0

        state.deleteSpace(id: "s2")

        #expect(state.spacesManager.activeSpaceId == "s1")
        #expect(state.selectedWorktreeId == "wt1")
        #expect(state.spacesManager.activeSpace?.lastSelectedWorktreeId == "wt1")
        #expect(spaceWriteCount == 1)
    }

    @Test func deletingFinalSpaceDoesNotPersist() {
        var spaceWriteCount = 0
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(
            projectsFile: ProjectsFile(projects: [project("p1")]),
            spacesFile: spaces,
            writes: { _, url in
                if url == Paths.spacesFile {
                    spaceWriteCount += 1
                }
            }
        ))
        spaceWriteCount = 0

        state.deleteSpace(id: "s1")

        #expect(state.spacesManager.activeSpaceId == "s1")
        #expect(state.spacesManager.spaces.count == 1)
        #expect(spaceWriteCount == 0)
    }

    @Test func togglingFinalProjectSpaceMembershipDoesNotPersistNoOp() {
        var writeCount = 0
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(
            projectsFile: ProjectsFile(projects: [project("p1")]),
            spacesFile: spaces,
            writes: { _, _ in writeCount += 1 }
        ))
        writeCount = 0

        state.toggleProject(projectId: "p1", inSpace: "s1")

        #expect(writeCount == 0)
        #expect(state.spacesManager.space(id: "s1")?.projectIds == ["p1"])
    }

    @Test func mainSpaceCanOmitProjectThatRemainsInAnotherSpace() {
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "main",
            spaces: [
                SpaceConfig(id: "main", name: "Main", emoji: "🏠", projectIds: ["p1", "p2"], lastSelectedWorktreeId: "wt1", createdAt: Date()),
                SpaceConfig(id: "other", name: "Other", emoji: "✨", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))
        state.projectsManager.insertOptimisticWorktree(worktree("wt1", projectId: "p1"))
        state.projectsManager.insertOptimisticWorktree(worktree("wt2", projectId: "p2"))
        state.selectedWorktreeId = "wt1"

        state.toggleProject(projectId: "p1", inSpace: "main")

        #expect(state.spacesManager.space(id: "main")?.projectIds == ["p2"])
        #expect(state.spacesManager.space(id: "other")?.projectIds == ["p1"])
        #expect(state.activeSpaceProjects.map(\.id) == ["p2"])
        #expect(state.selectedWorktreeId == "wt2")
        #expect(state.spacesManager.activeSpace?.lastSelectedWorktreeId == "wt2")
    }

    @Test func updateSpaceRejectsPlainTextIcon() {
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Main", emoji: "🏠", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project("p1")]), spacesFile: spaces))

        state.updateSpace(id: "s1", name: "Main", emoji: "work")

        #expect(state.spacesManager.space(id: "s1")?.emoji == "🏠")
    }

    @Test func showSingleSpaceAffordanceSettingPersists() {
        var persistedFile: SpacesFile?
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Main", emoji: "🏠", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(
            projectsFile: ProjectsFile(projects: [project("p1")]),
            spacesFile: spaces,
            writes: { value, url in
                if url == Paths.spacesFile {
                    persistedFile = value as? SpacesFile
                }
            }
        ))

        state.setShowSingleSpaceAffordance(true)

        #expect(state.spacesManager.shouldShowSpaceAffordance)
        #expect(persistedFile?.showSingleSpaceAffordance == true)
    }

    @Test func switchingSpacesFallsBackToFirstVisibleWorktreeWhenRememberedSelectionIsStale() {
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: "missing", createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))
        state.projectsManager.insertOptimisticWorktree(worktree("wt2", projectId: "p2"))

        state.switchToSpace(id: "s2")

        #expect(state.spacesManager.activeSpaceId == "s2")
        #expect(state.selectedWorktreeId == "wt2")
        #expect(state.spacesManager.activeSpace?.lastSelectedWorktreeId == "wt2")
    }

    @Test func switchingSpacesFallsBackToFirstVisibleWorktreeWhenRememberedSelectionIsNil() {
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))
        state.projectsManager.insertOptimisticWorktree(worktree("wt2", projectId: "p2"))

        state.switchToSpace(id: "s2")

        #expect(state.spacesManager.activeSpaceId == "s2")
        #expect(state.selectedWorktreeId == "wt2")
        #expect(state.spacesManager.activeSpace?.lastSelectedWorktreeId == "wt2")
    }

    @Test func cleanupMissingActiveSpaceWorktreeDoesNotSelectOtherSpaceWorktree() async {
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: "wt1", createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: "wt2", createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))
        state.projectsManager.insertOptimisticWorktree(worktree("wt1", projectId: "p1"))
        state.projectsManager.insertOptimisticWorktree(worktree("wt2", projectId: "p2"))
        state.selectedWorktreeId = "wt1"
        let beforeIds = state.allWorktreeIds()
        state.projectsManager.removeOptimisticWorktree(id: "wt1", projectId: "p1")

        await state.cleanupMissingWorktrees(beforeIds: beforeIds)

        #expect(state.spacesManager.activeSpaceId == "s1")
        #expect(state.selectedWorktreeId == nil)
        #expect(state.spacesManager.activeSpace?.lastSelectedWorktreeId == nil)
    }

    @Test func removingFailedActiveSpaceWorktreeDoesNotSelectOtherSpaceWorktree() {
        var persistedProjects: ProjectsFile?
        var p1 = project("p1")
        p1.ggWorktreeModes["wt1"] = .on
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: "wt1", createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: "wt2", createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(
            projectsFile: ProjectsFile(projects: [p1, p2]),
            spacesFile: spaces,
            writes: { value, url in
                guard url == Paths.projectsFile else { return }
                persistedProjects = value as? ProjectsFile
            }
        ))
        state.projectsManager.insertOptimisticWorktree(worktree("wt1", projectId: "p1"))
        state.projectsManager.insertOptimisticWorktree(worktree("wt2", projectId: "p2"))
        state.selectedWorktreeId = "wt1"

        state.removeFailedOptimisticWorktree(id: "wt1", projectId: "p1")

        #expect(state.spacesManager.activeSpaceId == "s1")
        #expect(state.selectedWorktreeId == nil)
        #expect(state.spacesManager.activeSpace?.lastSelectedWorktreeId == nil)
        #expect(state.projectsManager.ggWorktreeMode(projectId: "p1", worktreeId: "wt1") == .inherit)
        #expect(persistedProjects?.projects.first { $0.id == "p1" }?.ggWorktreeModes["wt1"] == nil)
    }

    @Test func focusingGlobalWorktreeSwitchesToContainingSpace() {
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))

        state.focusGlobalWorktree(id: "wt2", projectId: "p2")

        #expect(state.spacesManager.activeSpaceId == "s2")
        #expect(state.selectedWorktreeId == "wt2")
    }

    @Test func repoSelectorEnvironmentSwitchesSpaceBeforeFocusingWorktree() {
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))
        let env = state.repoSelectorEnvironment(openNewProject: {}, openNewWorktree: { _ in })

        env.focusWorktree("wt2", "p2")

        #expect(state.spacesManager.activeSpaceId == "s2")
        #expect(state.selectedWorktreeId == "wt2")
    }

    @Test func createWorktreeFromInactiveSpaceSwitchesBeforeSelectingOptimisticRow() async throws {
        let repo = try await makeRepo(name: "create-inactive-space")
        let destination = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-space-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: destination)
        }
        let p1 = project("p1")
        let p2 = project("p2", path: repo.path)
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))
        state.config.worktrees.fetchRemoteBeforeCreate = false

        let id = await state.createWorktree(
            projectId: "p2",
            base: "main",
            branch: "space-create",
            destination: destination,
            runStartup: false,
            launchSurface: .none
        )

        #expect(!id.isEmpty)
        #expect(state.spacesManager.activeSpaceId == "s2")
        #expect(state.selectedWorktreeId == id)
        #expect(state.spacesManager.space(id: "s1")?.lastSelectedWorktreeId == nil)
        #expect(state.spacesManager.space(id: "s2")?.lastSelectedWorktreeId == id)
        #expect(state.activeSpaceProjects.map(\.id) == ["p2"])

        try await waitForOperationToClear(state.projectsManager, id: id)
    }
}
