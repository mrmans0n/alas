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

    @Test func appStateDefaultBridgeUsesTheInjectedWorkspaceStore() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [])
        let workspaceStore = WorkspaceStore(url: url)
        try await workspaceStore.checkpoint(.init(workspaces: [workspace]))
        let state = AppState(
            store: RecordingSpacesStore(spacesFile: emptySpacesFile()),
            persistenceErrorHandler: { _, _ in },
            restoreActiveTabsOnStartup: false,
            workspaceStore: workspaceStore
        )

        await state.setWorkspacesEnabled(true, persistConfig: false)

        #expect(state.workspacesManager.workspaces.map(\.id) == [workspace.id])
        guard case .loaded(let loadedState) = state.workspacesManager.loadState else {
            Issue.record("Expected AppState Workspace manager to load from the injected store")
            return
        }
        #expect(loadedState.workspaces.map(\.id) == [workspace.id])
    }

    @Test func enabledManagerPresentsReconciledMemberAvailabilityWithoutMutatingStorage() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        let memberID = UUID()
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-missing-workspace-member-\(UUID().uuidString)").path
        let member = WorkspaceCheckoutMember(
            id: memberID,
            workspaceMemberID: UUID(),
            projectID: "project",
            fallbackProjectName: "Project",
            fallbackRepositoryRoot: "/repo",
            worktreePath: missingPath,
            gitLineageID: "lineage",
            availability: .available,
            checkpoint: .setupComplete,
            cleanupOwnership: .init(worktreeCreated: true, branchOwnership: .created),
            plan: .init(
                checkoutMemberID: memberID,
                projectID: "project",
                sourceRepositoryPath: "/repo",
                destinationPath: missingPath,
                baseReference: "main",
                baseCommit: "abc",
                branchIntent: .create(atCommit: "abc")
            )
        )
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "release/1091",
            rootPath: "/checkout",
            operation: .idle,
            members: [member]
        )
        let store = WorkspaceStore(url: url)
        try await store.checkpoint(.init(checkouts: [checkout]))
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: store))

        await manager.setEnabled(true, spacesFile: emptySpacesFile())

        #expect(manager.checkout(id: checkout.id)?.members.first?.availability == .missing)
        guard case .loaded(let persistedState) = await store.load() else {
            Issue.record("Expected durable Workspace state")
            return
        }
        #expect(persistedState.checkouts.first?.members.first?.availability == .available)
    }

    @Test func reconciliationOverlayPreservesExplicitlyDeletedMembers() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        let memberID = UUID()
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-deleted-workspace-member-\(UUID().uuidString)").path
        let member = WorkspaceCheckoutMember(
            id: memberID,
            workspaceMemberID: UUID(),
            projectID: "project",
            fallbackProjectName: "Project",
            fallbackRepositoryRoot: "/repo",
            worktreePath: missingPath,
            gitLineageID: nil,
            availability: .explicitlyDeleted,
            checkpoint: .planPersisted,
            cleanupOwnership: .init(),
            plan: .init(
                checkoutMemberID: memberID,
                projectID: "project",
                sourceRepositoryPath: "/repo",
                destinationPath: missingPath,
                baseReference: "main",
                baseCommit: "abc",
                branchIntent: .create(atCommit: "abc")
            )
        )
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "release/1091",
            rootPath: "/checkout",
            operation: .idle,
            members: [member]
        )
        let store = WorkspaceStore(url: url)
        try await store.checkpoint(.init(checkouts: [checkout]))
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: store))

        await manager.setEnabled(true, spacesFile: emptySpacesFile())

        #expect(manager.checkout(id: checkout.id)?.members.first?.availability == .explicitlyDeleted)
    }

    @Test func managerLookupKeepsArchivedCheckoutsSelectableForUnarchive() async throws {
        let url = temporaryURL()
        defer { removeWorkspaceFiles(near: url) }
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "release/1091",
            rootPath: "/checkout",
            archivedAt: Date(timeIntervalSince1970: 10),
            members: []
        )
        let store = WorkspaceStore(url: url)
        try await store.checkpoint(.init(checkouts: [checkout]))
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: store))

        await manager.setEnabled(true, spacesFile: emptySpacesFile())

        #expect(manager.checkout(id: checkout.id)?.archivedAt == checkout.archivedAt)
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
        let persistence = RecordingSpacesStore(
            spacesFile: spaces,
            projectsFile: ProjectsFile(projects: [
                ProjectConfig(id: "project", name: "Project", path: "/repos/project", color: "#ffffff", addedAt: .distantPast),
            ])
        )
        let state = AppState(
            store: persistence,
            persistenceErrorHandler: { _, _ in },
            restoreActiveTabsOnStartup: false,
            workspacesManager: manager,
            workspaceStore: WorkspaceStore(url: URL(fileURLWithPath: "/dev/null/workspaces.json"))
        )
        state.config.workspacesEnabled = true
        let originalSpacesFile = state.spacesManager.file
        let originalSpacesWriteCount = persistence.spacesWriteCount
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [])

        await #expect(throws: WorkspaceDefinitionSaveError.workspacePersistenceFailed) {
            try await state.saveWorkspaceDefinition(workspace)
        }

        #expect(persistence.spacesWriteCount == originalSpacesWriteCount + 2)
        #expect(persistence.writtenSpaces.last == originalSpacesFile)
        #expect(state.spacesManager.file == originalSpacesFile)
        #expect(state.workspacesManager.workspaces.isEmpty)
    }

    @Test @MainActor func appStateCreationPersistsResolvedConfigurationSnapshot() async throws {
        let workspaceURL = temporaryURL()
        let checkoutRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-workspace-config-\(UUID().uuidString)", isDirectory: true)
        defer {
            removeWorkspaceFiles(near: workspaceURL)
            try? FileManager.default.removeItem(at: checkoutRoot)
        }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let spaces = emptySpacesFile()
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        _ = await manager.setEnabled(true, spacesFile: spaces)
        let state = AppState(
            store: RecordingSpacesStore(spacesFile: spaces),
            persistenceErrorHandler: { _, _ in },
            restoreActiveTabsOnStartup: false,
            workspacesManager: manager,
            workspaceStore: workspaceStore
        )
        state.config.workspacesEnabled = true
        state.config.terminal.worktreeCreateScript = "global setup"
        let workspace = Workspace(
            name: "Release",
            executionLocation: .local,
            members: [],
            configuration: .init(sharedStartupScripts: .init(
                sessionOpenMode: .useGlobal,
                sessionOpenScript: "",
                worktreeCreateMode: .overrideGlobal,
                worktreeCreateScript: "workspace setup"
            ))
        )
        let plan = FrozenWorkspaceCheckoutPlan(
            checkoutID: UUID(),
            workspaceID: workspace.id,
            executionLocation: .local,
            branch: "release/1091",
            rootPath: checkoutRoot.path,
            members: []
        )

        let checkout = try await state.createWorkspaceCheckout(workspace: workspace, plan: plan)
        await state.workspaceCoordinator().awaitCreationCompletion(checkoutID: checkout.id)

        guard let persisted = await workspaceStore.checkout(id: checkout.id) else {
            Issue.record("Expected persisted checkout")
            return
        }
        #expect(persisted.configurationSnapshot?.shared.worktreeCreateScript == "workspace setup")
    }

    @Test @MainActor func appStateAppliesFrozenACPCreationLaunchPreferenceAfterCheckoutCompletes() async throws {
        let workspaceURL = temporaryURL()
        let checkoutRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-workspace-launch-\(UUID().uuidString)", isDirectory: true)
        defer {
            removeWorkspaceFiles(near: workspaceURL)
            try? FileManager.default.removeItem(at: checkoutRoot)
        }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let spaces = emptySpacesFile()
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        _ = await manager.setEnabled(true, spacesFile: spaces)
        let state = AppState(
            store: RecordingSpacesStore(spacesFile: spaces),
            persistenceErrorHandler: { _, _ in },
            restoreActiveTabsOnStartup: false,
            workspacesManager: manager,
            workspaceStore: workspaceStore
        )
        state.config.workspacesEnabled = true
        let agent = AgentDefinition(
            id: "workspace-test-agent",
            displayName: "Workspace Test Agent",
            binary: "workspace-test-agent",
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: "--unsafe",
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
        state.agentRegistry = AgentRegistry(builtinState: [:], customs: [agent], installedIds: [agent.id])
        let workspace = Workspace(
            name: "Release",
            executionLocation: .local,
            members: [],
            configuration: .init(creationLaunchPreference: .override(.init(
                openAfterCreate: true,
                launcherMode: .acp,
                agentID: agent.id,
                useBypassPermissions: true
            )))
        )
        let plan = FrozenWorkspaceCheckoutPlan(
            checkoutID: UUID(),
            workspaceID: workspace.id,
            executionLocation: .local,
            branch: "release/1091",
            rootPath: checkoutRoot.path,
            members: []
        )

        let checkout = try await state.createWorkspaceCheckout(workspace: workspace, plan: plan)
        await state.workspaceCoordinator().awaitCreationCompletion(checkoutID: checkout.id)
        try await waitForCheckoutOwnedACPTab(state: state, checkout: checkout)

        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let acpTabs = state.tabs.tabs(for: owner).filter {
            if case .acpSession = $0 { return true }
            return false
        }
        #expect(acpTabs.count == 1)
    }

    @Test @MainActor func deletingWorkspaceDefinitionRemovesSpacePlacementAndKeepsFormerCheckoutSnapshot() async throws {
        let workspaceURL = temporaryURL()
        defer { removeWorkspaceFiles(near: workspaceURL) }
        let workspace = Workspace(name: "Release", executionLocation: .local, members: [])
        let memberID = UUID()
        let checkout = WorkspaceCheckout(
            workspaceID: workspace.id,
            fallbackWorkspaceName: workspace.name,
            executionLocation: .local,
            branch: "release/1091",
            rootPath: "/checkouts/release",
            members: [
                WorkspaceCheckoutMember(
                    id: memberID,
                    workspaceMemberID: UUID(),
                    projectID: "project",
                    fallbackProjectName: "Project",
                    fallbackRepositoryRoot: "/repos/project",
                    worktreePath: "/checkouts/release/project",
                    gitLineageID: "lineage",
                    availability: .available,
                    checkpoint: .setupComplete,
                    cleanupOwnership: .init(worktreeCreated: true, branchOwnership: .created),
                    plan: .init(
                        checkoutMemberID: memberID,
                        projectID: "project",
                        sourceRepositoryPath: "/repos/project",
                        destinationPath: "/checkouts/release/project",
                        baseReference: "main",
                        baseCommit: "abc",
                        branchIntent: .create(atCommit: "abc")
                    )
                ),
            ]
        )
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        try await workspaceStore.checkpoint(.init(workspaces: [workspace], checkouts: [checkout]))
        let spaces = SpacesFile(activeSpaceId: "space", spaces: [
            SpaceConfig(
                id: "space",
                name: "Default",
                emoji: "folder",
                projectIds: ["project"],
                members: [.project("project"), .workspace(workspace.id)],
                lastSelectedWorktreeId: nil,
                createdAt: .distantPast
            ),
        ])
        let persistence = RecordingSpacesStore(
            spacesFile: spaces,
            projectsFile: ProjectsFile(projects: [
                ProjectConfig(id: "project", name: "Project", path: "/repos/project", color: "#ffffff", addedAt: .distantPast),
            ])
        )
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        _ = await manager.setEnabled(true, spacesFile: spaces)
        let state = AppState(
            store: persistence,
            persistenceErrorHandler: { _, _ in },
            restoreActiveTabsOnStartup: false,
            workspacesManager: manager,
            workspaceStore: workspaceStore
        )
        state.config.workspacesEnabled = true
        state.selectWorkspace(id: workspace.id)

        try await state.deleteWorkspaceDefinition(id: workspace.id)

        #expect(state.spacesManager.activeSpace?.members == [.project("project")])
        #expect(persistence.writtenSpaces.last?.spaces.first?.members == [.project("project")])
        guard case .loaded(let stored) = await workspaceStore.load() else {
            Issue.record("Expected stored Workspace state")
            return
        }
        #expect(stored.workspaces.isEmpty)
        #expect(stored.checkouts.first?.workspaceID == nil)
        #expect(stored.checkouts.first?.fallbackWorkspaceName == "Release")
        #expect(state.workspaceNavigationState.selectedWorkspaceID == nil)
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

    private func waitForCheckoutOwnedACPTab(
        state: AppState,
        checkout: WorkspaceCheckout,
        timeoutSeconds: Double = 5
    ) async throws {
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if state.tabs.tabs(for: owner).contains(where: {
                if case .acpSession = $0 { return true }
                return false
            }) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Timed out waiting for checkout-owned ACP tab")
    }
}
