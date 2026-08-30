import Foundation
import Testing
@testable import Alas

@Suite("Workspace feature flag")
@MainActor
struct WorkspaceFeatureFlagTests {
    @Test func disabledManagerDoesNotLoadOrReconcileWorkspaceStorage() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let state = WorkspaceStateFile(workspaces: [
            Workspace(name: "Release", executionLocation: .local, members: [])
        ])
        let store = WorkspaceStore(url: url)
        try await store.checkpoint(state)
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: store))

        await manager.setEnabled(false, spacesFile: emptySpacesFile())

        #expect(manager.loadState == .notLoaded)
        guard case .loaded(let storedState) = await store.load() else {
            Issue.record("Expected dormant Workspace state to remain readable")
            return
        }
        #expect(storedState.workspaces.map(\.id) == state.workspaces.map(\.id))
    }

    @Test func enabledManagerLoadsWorkspaceStorage() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let state = WorkspaceStateFile(workspaces: [
            Workspace(name: "Release", executionLocation: .local, members: [])
        ])
        let store = WorkspaceStore(url: url)
        try await store.checkpoint(state)
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: store))

        await manager.setEnabled(true, spacesFile: emptySpacesFile())

        guard case .loaded(let loadedState) = manager.loadState else {
            Issue.record("Expected enabled Workspace state")
            return
        }
        #expect(loadedState.workspaces.map(\.id) == state.workspaces.map(\.id))
        #expect(manager.canMutate == true)
        guard case .loaded(let persistedState) = await store.load() else {
            Issue.record("Expected Workspace storage to remain readable")
            return
        }
        #expect(persistedState.spaceLayouts == [])
    }

    @Test func unreadableStorageMakesEnabledManagerReadOnlyWithoutRewrite() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        try Data("not JSON".utf8).write(to: url)
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: WorkspaceStore(url: url)))

        await manager.setEnabled(true, spacesFile: emptySpacesFile())

        guard case .unreadable = manager.loadState else {
            Issue.record("Expected recovery state")
            return
        }
        #expect(manager.canMutate == false)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        #expect((try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .contains(where: { $0.lastPathComponent.hasPrefix("\(url.lastPathComponent).broken-") })) == true)
    }

    @Test func appStateSurfacesWorkspaceRecoveryError() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        try Data("not JSON".utf8).write(to: url)
        let manager = WorkspacesManager(
            bridge: WorkspaceSpacePersistenceBridge(workspaceStore: WorkspaceStore(url: url))
        )
        let state = AppState(
            store: MemoryStore(),
            persistenceErrorHandler: { _, _ in },
            workspacesManager: manager
        )

        await state.setWorkspacesEnabled(true)

        #expect(state.workspaceRecoveryError != nil)
    }

    @Test func enablingReupgradeDoesNotWriteLegacySpaces() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        let workspaceID = UUID()
        let workspaceStore = WorkspaceStore(url: url)
        try await workspaceStore.checkpoint(WorkspaceStateFile(spaceLayouts: [
            WorkspaceSpaceLayout(
                spaceID: "space",
                members: [.project("project"), .workspace(workspaceID)],
                legacyProjectIDs: ["project"]
            )
        ]))
        let legacySpaces = SpacesFile(activeSpaceId: "space", spaces: [
            SpaceConfig(id: "space", name: "Default", emoji: "folder", projectIds: ["project"], lastSelectedWorktreeId: nil, createdAt: .distantPast)
        ])
        let persistence = RecordingSpacesStore(
            spacesFile: legacySpaces,
            projectsFile: ProjectsFile(projects: [
                ProjectConfig(id: "project", name: "Project", path: "/repo", color: "#ffffff", addedAt: .distantPast)
            ])
        )
        let state = AppState(
            store: persistence,
            workspacesManager: WorkspacesManager(
                bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore)
            )
        )

        await state.setWorkspacesEnabled(true, persistConfig: false)

        #expect(persistence.spacesWriteCount == 0)
        #expect(state.spacesManager.activeSpace?.members == [.project("project"), .workspace(workspaceID)])
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private final class RecordingSpacesStore: PersistenceStoreProtocol, @unchecked Sendable {
        let spacesFile: SpacesFile
        let projectsFile: ProjectsFile
        private(set) var spacesWriteCount = 0
        private(set) var writtenSpaces: [SpacesFile] = []

        init(spacesFile: SpacesFile, projectsFile: ProjectsFile = ProjectsFile(projects: [])) {
            self.spacesFile = spacesFile
            self.projectsFile = projectsFile
        }

        func write<T: Encodable>(_ value: T, to _: URL) throws {
            if let spaces = value as? SpacesFile {
                spacesWriteCount += 1
                writtenSpaces.append(spaces)
            }
        }

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            if type == SpacesFile.self { return spacesFile as? T }
            if type == ProjectsFile.self { return projectsFile as? T }
            return nil
        }
    }

    private func emptySpacesFile() -> SpacesFile {
        SpacesFile(activeSpaceId: "space", spaces: [
            SpaceConfig(id: "space", name: "Default", emoji: "folder", projectIds: [], lastSelectedWorktreeId: nil, createdAt: .distantPast)
        ])
    }

    @Test @MainActor func failedSpacePlacementDoesNotPersistOrLeaveInvisibleWorkspace() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        let workspaceStore = WorkspaceStore(url: url)
        let spaces = emptySpacesFile()
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        _ = await manager.setEnabled(true, spacesFile: spaces)
        let state = AppState(
            store: ThrowingSpacesStore(spacesFile: spaces),
            persistenceErrorHandler: { _, _ in },
            restoreActiveTabsOnStartup: false,
            workspacesManager: manager,
            workspaceStore: workspaceStore
        )
        state.config.workspacesEnabled = true
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [])

        await #expect(throws: WorkspaceDefinitionSaveError.spacePlacementFailed) {
            try await state.saveWorkspaceDefinition(workspace)
        }

        #expect(state.spacesManager.activeSpace?.members == nil)
        #expect(state.spacesManager.activeSpace?.projectIds == [])
        #expect(await workspaceStore.load() == .missing)
        #expect(state.workspacesManager.workspaces.isEmpty)
    }

    @Test @MainActor func failedWorkspacePersistenceRollsBackSuccessfulSpacePlacement() async throws {
        let spaces = emptySpacesFile()
        let managerURL = temporaryURL()
        defer { removeWorkspaceFiles(near: managerURL) }
        let manager = WorkspacesManager(
            bridge: WorkspaceSpacePersistenceBridge(workspaceStore: WorkspaceStore(url: managerURL))
        )
        _ = await manager.setEnabled(true, spacesFile: spaces)
        let persistence = RecordingSpacesStore(spacesFile: spaces)
        let state = AppState(
            store: persistence,
            persistenceErrorHandler: { _, _ in },
            restoreActiveTabsOnStartup: false,
            workspacesManager: manager,
            workspaceStore: WorkspaceStore(url: URL(fileURLWithPath: "/dev/null/workspaces.json"))
        )
        state.config.workspacesEnabled = true
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [])

        await #expect(throws: WorkspaceDefinitionSaveError.workspacePersistenceFailed) {
            try await state.saveWorkspaceDefinition(workspace)
        }

        #expect(persistence.spacesWriteCount == 2)
        #expect(persistence.writtenSpaces.last == spaces)
        #expect(state.spacesManager.file == spaces)
        #expect(state.workspacesManager.workspaces.isEmpty)
    }

    private final class ThrowingSpacesStore: PersistenceStoreProtocol, @unchecked Sendable {
        let spacesFile: SpacesFile
        init(spacesFile: SpacesFile) { self.spacesFile = spacesFile }
        func write<T: Encodable>(_ value: T, to _: URL) throws { if value is SpacesFile { throw NSError(domain: "test", code: 1) } }
        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? { type == SpacesFile.self ? spacesFile as? T : nil }
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-workspace-feature-\(UUID().uuidString).json")
    }

    private func removeWorkspaceFiles(near url: URL) {
        let directory = url.deletingLastPathComponent()
        for entry in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where entry.lastPathComponent.hasPrefix(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
