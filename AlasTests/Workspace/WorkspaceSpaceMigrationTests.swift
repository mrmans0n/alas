import Foundation
import Testing
@testable import Alas

@Suite("Workspace Space migration")
struct WorkspaceSpaceMigrationTests {
    private let workspaceA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let workspaceB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func space(
        _ id: String,
        projects: [String],
        members: [SpaceMemberReference]? = nil
    ) -> SpaceConfig {
        SpaceConfig(
            id: id,
            name: id,
            emoji: "🏠",
            projectIds: projects,
            members: members,
            lastSelectedWorktreeId: nil,
            createdAt: date
        )
    }

    private struct AppStateStore: PersistenceStoreProtocol {
        let projectsFile: ProjectsFile
        let spacesFile: SpacesFile

        func write<T: Encodable>(_ value: T, to url: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            if type == ProjectsFile.self { return projectsFile as? T }
            if type == SpacesFile.self { return spacesFile as? T }
            if type == AppConfig.self {
                var config = AppConfig.defaults
                config.workspacesEnabled = true
                return config as? T
            }
            return nil
        }
    }

    private func project(_ id: String) -> ProjectConfig {
        ProjectConfig(
            id: id,
            name: id,
            path: "/tmp/\(id)",
            color: "#5fb7c4",
            addedAt: date
        )
    }

    @Test func reupgradeMergesOlderProjectRewriteIntoTypedLayout() {
        let saved = [
            WorkspaceSpaceLayout(
                spaceID: "work",
                members: [.project("p1"), .workspace(workspaceA), .project("p2"), .workspace(workspaceB)],
                legacyProjectIDs: ["p1", "p2"]
            )
        ]
        let downgraded = SpacesFile(
            activeSpaceId: "work",
            spaces: [space("work", projects: ["p2", "p3"])]
        )

        var state = WorkspaceStateFile(spaceLayouts: saved)
        let reupgradedSpaces = state.reconcileSpaceLayouts(with: downgraded)

        #expect(reupgradedSpaces.spaces.first?.members == [
            .project("p2"), .workspace(workspaceA), .project("p3"), .workspace(workspaceB)
        ])
        #expect(reupgradedSpaces.spaces.first?.projectIds == ["p2", "p3"])
        #expect(state.spaceLayouts.first?.legacyProjectIDs == ["p2", "p3"])
    }

    @Test func reupgradeMovesDeletedSpaceWorkspacesToActiveSpaceAndKeepsNewSpacesProjectOnly() {
        let saved = [
            WorkspaceSpaceLayout(
                spaceID: "removed",
                members: [.project("p1"), .workspace(workspaceA)],
                legacyProjectIDs: ["p1"]
            ),
            WorkspaceSpaceLayout(
                spaceID: "active",
                members: [.workspace(workspaceB), .project("p2")],
                legacyProjectIDs: ["p2"]
            )
        ]
        let downgraded = SpacesFile(
            activeSpaceId: "active",
            spaces: [
                space("active", projects: ["p2"]),
                space("new", projects: ["p3"])
            ]
        )

        let migrated = WorkspaceSpaceMigration.reupgrade(
            spacesFile: downgraded,
            savedLayouts: saved
        )

        #expect(migrated.spaces.first(where: { $0.id == "active" })?.members == [
            .workspace(workspaceB), .project("p2"), .workspace(workspaceA)
        ])
        #expect(migrated.spaces.first(where: { $0.id == "new" })?.members == [.project("p3")])
        #expect(migrated.layouts.map(\.spaceID) == ["active", "new"])
    }

    @Test func loadedWorkspaceStateReconcilesOlderSpacesBeforeRefreshingLayouts() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-workspace-spaces-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("recovery"))
        }
        let store = WorkspaceStore(url: url)
        let saved = WorkspaceSpaceLayout(
            spaceID: "work",
            members: [.project("p1"), .workspace(workspaceA), .project("p2")],
            legacyProjectIDs: ["p1", "p2"]
        )
        try await store.checkpoint(WorkspaceStateFile(spaceLayouts: [saved]))
        let legacySpaces = SpacesFile(
            activeSpaceId: "work",
            spaces: [space("work", projects: ["p2", "p3"])]
        )

        let bridge = WorkspaceSpacePersistenceBridge(workspaceStore: store)
        let reconciled = try await bridge.reconcileOnLoad(spacesFile: legacySpaces)

        #expect(reconciled?.spaces.first?.members == [.project("p2"), .workspace(workspaceA), .project("p3")])
        guard case .loaded(let checkpointed) = await store.load() else {
            Issue.record("Expected checkpointed Workspace state")
            return
        }
        #expect(checkpointed.spaceLayouts.first?.legacyProjectIDs == ["p2", "p3"])
    }

    @Test func appStateStartupAppliesPersistedReupgradeToItsSpacesManager() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-workspace-spaces-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("recovery"))
        }
        let workspaceStore = WorkspaceStore(url: url)
        try await workspaceStore.checkpoint(WorkspaceStateFile(spaceLayouts: [
            WorkspaceSpaceLayout(
                spaceID: "work",
                members: [.project("p1"), .workspace(workspaceA), .project("p2")],
                legacyProjectIDs: ["p1", "p2"]
            )
        ]))
        let appState = await MainActor.run {
            AppState(
                store: AppStateStore(
                    projectsFile: ProjectsFile(projects: [project("p2"), project("p3")]),
                    spacesFile: SpacesFile(activeSpaceId: "work", spaces: [space("work", projects: ["p2", "p3"])])
                ),
                workspaceSpacePersistenceBridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore)
            )
        }

        for _ in 0 ..< 20 {
            let members = await MainActor.run { appState.spacesManager.activeSpace?.members }
            if members == [.project("p2"), .workspace(workspaceA), .project("p3")] {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("AppState did not apply the persisted Workspace Space layout")
    }

    @Test func serializedLayoutCheckpointPreservesWorkspaceStateAndLatestLayout() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-workspace-spaces-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("recovery"))
        }
        let store = WorkspaceStore(url: url)
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [])
        try await store.checkpoint(WorkspaceStateFile(workspaces: [workspace]))

        try await store.checkpointSpaceLayouts(afterWriting: SpacesFile(
            activeSpaceId: "work",
            spaces: [space("work", projects: ["p1"], members: [.project("p1"), .workspace(workspaceA)])]
        ))
        try await store.checkpointSpaceLayouts(afterWriting: SpacesFile(
            activeSpaceId: "work",
            spaces: [space("work", projects: ["p2"], members: [.workspace(workspaceA), .project("p2")])]
        ))

        guard case .loaded(let state) = await store.load() else {
            Issue.record("Expected persisted Workspace state")
            return
        }
        #expect(state.workspaces.map(\.id) == [workspace.id])
        #expect(state.workspaces.map(\.name) == [workspace.name])
        #expect(state.spaceLayouts == [
            WorkspaceSpaceLayout(
                spaceID: "work",
                members: [.workspace(workspaceA), .project("p2")],
                legacyProjectIDs: ["p2"]
            )
        ])
    }

    @Test func bridgeReportsUnreadableWorkspaceStorageInsteadOfDroppingLayoutCheckpoint() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-workspace-spaces-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("recovery"))
        }
        try Data("invalid".utf8).write(to: url)
        let bridge = WorkspaceSpacePersistenceBridge(workspaceStore: WorkspaceStore(url: url))

        await #expect(throws: WorkspaceStoreError.recoveryRequired) {
            try await bridge.checkpointAfterSpacesWrite(SpacesFile(
                activeSpaceId: "work",
                spaces: [space("work", projects: ["p1"])]
            ))
        }
    }
}
