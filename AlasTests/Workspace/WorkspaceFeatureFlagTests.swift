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
        let state = AppState(store: MemoryStore(), workspacesManager: manager)

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
        let persistence = RecordingSpacesStore(spacesFile: legacySpaces)
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
        private(set) var spacesWriteCount = 0

        init(spacesFile: SpacesFile) {
            self.spacesFile = spacesFile
        }

        func write<T: Encodable>(_ value: T, to _: URL) throws {
            if value is SpacesFile { spacesWriteCount += 1 }
        }

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            if type == SpacesFile.self { return spacesFile as? T }
            return nil
        }
    }

    private func emptySpacesFile() -> SpacesFile {
        SpacesFile(activeSpaceId: "space", spaces: [
            SpaceConfig(id: "space", name: "Default", emoji: "folder", projectIds: [], lastSelectedWorktreeId: nil, createdAt: .distantPast)
        ])
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
