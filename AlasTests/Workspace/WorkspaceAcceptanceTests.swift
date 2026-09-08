import Foundation
import Testing
@testable import Alas

@Suite("Workspace preview acceptance matrix")
struct WorkspaceAcceptanceTests {
    @Test func downgradeRewriteAndReupgradePreserveWorkspaceRecordsAndMixedSpacePlacement() throws {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let workspace = Workspace(
            id: workspaceID,
            name: "Release",
            executionLocation: .local,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            members: [
                WorkspaceMember(projectID: "p1", fallbackProjectName: "Project 1", fallbackRepositoryRoot: "/repos/p1"),
                WorkspaceMember(projectID: "p2", fallbackProjectName: "Project 2", fallbackRepositoryRoot: "/repos/p2"),
            ]
        )
        let currentSpaces = SpacesFile(activeSpaceId: "main", spaces: [
            SpaceConfig(
                id: "main",
                name: "Main",
                emoji: "🏠",
                projectIds: ["p1", "p2"],
                members: [.project("p1"), .workspace(workspaceID), .project("p2")],
                lastSelectedWorktreeId: nil,
                createdAt: .distantPast
            ),
        ])
        let originalState = WorkspaceStateFile(
            workspaces: [workspace],
            spaceLayouts: WorkspaceSpaceMigration.layouts(for: currentSpaces.spaces)
        )
        let roundTrippedState = try JSONDecoder.workspace.decode(
            WorkspaceStateFile.self,
            from: JSONEncoder.workspace.encode(originalState)
        )

        let olderBuildRewrite = SpacesFile(activeSpaceId: "main", spaces: [
            SpaceConfig(
                id: "main",
                name: "Main",
                emoji: "🏠",
                projectIds: ["p2", "p1", "p3"],
                members: nil,
                lastSelectedWorktreeId: nil,
                createdAt: .distantPast
            ),
        ])
        var reupgradedState = roundTrippedState
        let reupgradedSpaces = reupgradedState.reconcileSpaceLayouts(with: olderBuildRewrite)

        #expect(roundTrippedState.workspaces.map(\.id) == [workspaceID])
        #expect(reupgradedSpaces.spaces.first?.members == [
            .project("p2"),
            .workspace(workspaceID),
            .project("p1"),
            .project("p3"),
        ])
        #expect(reupgradedSpaces.spaces.first?.projectIds == ["p2", "p1", "p3"])
        #expect(reupgradedState.workspaces.map(\.id) == [workspaceID])
    }

    @Test func unreadableWorkspaceStorageBlocksAutomationAndOrdinaryCheckpointOverwrite() async throws {
        let url = temporaryDirectory().appendingPathComponent("workspaces.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"checkouts":["not a checkout"]}"#.utf8).write(to: url)
        let store = WorkspaceStore(url: url)
        let service = WorkspaceAutomationService(store: store, isEnabled: { true })

        await #expect(throws: WorkspaceAutomationError.recoveryRequired) {
            try await service.listCheckouts()
        }
        await #expect(throws: WorkspaceStoreError.recoveryRequired) {
            try await store.checkpoint(WorkspaceStateFile())
        }
        guard case .unreadable(let recovery) = await store.load() else {
            Issue.record("Expected unreadable storage to remain recoverable")
            return
        }
        #expect(recovery.originalFilePath == url.path)
        #expect(recovery.quarantinedFilePath != nil)
    }

    @Test @MainActor func featureFlagOffAndMissingStorageDoNotImportIndependentWorktrees() async throws {
        let workspaceURL = temporaryDirectory().appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(url: workspaceURL)
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: store))
        let spaces = SpacesFile(activeSpaceId: "main", spaces: [
            SpaceConfig(
                id: "main",
                name: "Main",
                emoji: "🏠",
                projectIds: ["existing-project"],
                members: nil,
                lastSelectedWorktreeId: nil,
                createdAt: .distantPast
            ),
        ])

        _ = await manager.setEnabled(false, spacesFile: spaces)
        #expect(manager.loadState == .notLoaded)
        #expect(FileManager.default.fileExists(atPath: workspaceURL.path) == false)

        _ = await manager.setEnabled(true, spacesFile: spaces)
        #expect(manager.workspaces.isEmpty)
        #expect(manager.checkouts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: workspaceURL.path) == false)
    }

    @Test func ownerStorageKeepsLegacyWorktreeCompatibilityAndNamespacedCheckoutIdentity() {
        let checkoutID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let checkoutOwner = SessionOwnerID.workspaceCheckout(checkoutID, .ssh("devbox"))
        let legacyAlias = SessionOwnerID.worktree(checkoutOwner.storageKey)

        #expect(SessionOwnerID.worktree("feature/login").storageKey == "feature/login")
        #expect(legacyAlias != checkoutOwner)
        #expect(checkoutOwner.storageKey.hasPrefix("workspace-checkout--22222222-2222-2222-2222-222222222222--"))
    }

    @Test func resumableCreationAndLifecycleCheckpointsSurviveVersionedRoundTrip() throws {
        let memberID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let checkoutID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let member = WorkspaceCheckoutMember(
            id: memberID,
            workspaceMemberID: UUID(),
            projectID: "project-a",
            fallbackProjectName: "Project A",
            fallbackRepositoryRoot: "/repos/a",
            worktreePath: "/workspace/a",
            gitLineageID: "lineage-a",
            availability: .available,
            checkpoint: .worktreeCreated,
            cleanupOwnership: .init(worktreeCreated: true, branchOwnership: .created),
            plan: .init(
                checkoutMemberID: memberID,
                projectID: "project-a",
                sourceRepositoryPath: "/repos/a",
                destinationPath: "/workspace/a",
                baseReference: "main",
                baseCommit: "abc123",
                branchIntent: .create(atCommit: "abc123")
            ),
            cleanup: WorkspaceCheckoutMemberCleanup(
                plan: .init(
                    checkoutID: checkoutID,
                    memberID: memberID,
                    executionLocation: .local,
                    projectID: "project-a",
                    sourceRepositoryPath: "/repos/a",
                    baseReference: "main",
                    baseCommit: "abc123",
                    rootPath: "/workspace",
                    managedMemberPaths: ["/workspace/a"],
                    worktreePath: "/workspace/a",
                    branch: "release",
                    expectedLineageID: "lineage-a",
                    branchOwnership: .created
                ),
                checkpoint: .worktreeRemoved,
                worktreeRemoved: true,
                branchRemoved: false
            )
        )
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: UUID(),
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "release",
            rootPath: "/workspace",
            operation: .creating,
            members: [member]
        )

        let decoded = try JSONDecoder.workspace.decode(
            WorkspaceStateFile.self,
            from: JSONEncoder.workspace.encode(WorkspaceStateFile(checkouts: [checkout]))
        )

        #expect(decoded.version == 1)
        #expect(decoded.checkouts.first?.operation == .creating)
        #expect(decoded.checkouts.first?.health == .ready)
        #expect(decoded.checkouts.first?.members.first?.checkpoint == .worktreeCreated)
        #expect(decoded.checkouts.first?.members.first?.cleanup?.worktreeRemoved == true)
        #expect(decoded.checkouts.first?.members.first?.cleanup?.branchRemoved == false)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-workspace-acceptance-\(UUID().uuidString)", isDirectory: true)
    }
}
