import Foundation
import Testing
@testable import Alas

@Suite("Workspace models")
struct WorkspaceModelsTests {
    @Test func stateRoundTripsStableWorkspaceAndCheckoutIDs() throws {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let memberID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let checkoutID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let checkoutMemberID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let state = WorkspaceStateFile(
            workspaces: [
                Workspace(
                    id: workspaceID,
                    name: "Release train",
                    executionLocation: .ssh(" builder.example "),
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    members: [
                        WorkspaceMember(
                            id: memberID,
                            projectID: "project-a",
                            fallbackProjectName: "Alas",
                            fallbackRepositoryRoot: "/src/alas"
                        )
                    ]
                )
            ],
            checkouts: [
                WorkspaceCheckout(
                    id: checkoutID,
                    workspaceID: workspaceID,
                    fallbackWorkspaceName: "Release train",
                    executionLocation: .ssh("builder.example"),
                    branch: "release/1.0",
                    rootPath: "/tmp/release-train",
                    createdAt: createdAt,
                    members: [
                        WorkspaceCheckoutMember(
                            id: checkoutMemberID,
                            workspaceMemberID: memberID,
                            projectID: "project-a",
                            fallbackProjectName: "Alas",
                            fallbackRepositoryRoot: "/src/alas",
                            worktreePath: "/tmp/release-train/alas",
                            gitLineageID: "abc123"
                        )
                    ]
                )
            ]
        )

        let data = try JSONEncoder.workspace.encode(state)
        let decoded = try JSONDecoder.workspace.decode(WorkspaceStateFile.self, from: data)

        #expect(decoded == state)
        #expect(decoded.workspaces.first?.executionLocation == .ssh("builder.example"))
        #expect(decoded.checkouts.first?.id == checkoutID)
        #expect(decoded.checkouts.first?.members.first?.id == checkoutMemberID)
    }

    @Test func newlyOptionalFieldsDecodeWithSafeDefaults() throws {
        let data = Data("""
        {
          "version": 1,
          "workspaces": [],
          "checkouts": []
        }
        """.utf8)

        let decoded = try JSONDecoder.workspace.decode(WorkspaceStateFile.self, from: data)

        #expect(decoded.version == WorkspaceStateFile.currentVersion)
        #expect(decoded.workspaces.isEmpty)
        #expect(decoded.checkouts.isEmpty)
    }

    @Test func omittedCheckoutRecordFieldsDecodeToDurableDefaults() throws {
        let checkoutID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let memberID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let workspaceMemberID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let data = Data("""
        {
          "version": 1,
          "workspaces": [],
          "checkouts": [{
            "id": "\(checkoutID.uuidString)",
            "fallbackWorkspaceName": "Release train",
            "executionLocation": { "kind": "local" },
            "branch": "release/1.0",
            "rootPath": "/tmp/release-train",
            "createdAt": "2023-11-14T22:13:20Z",
            "members": [{
              "id": "\(memberID.uuidString)",
              "workspaceMemberID": "\(workspaceMemberID.uuidString)",
              "projectID": "project-a",
              "fallbackProjectName": "Alas",
              "fallbackRepositoryRoot": "/src/alas",
              "worktreePath": "/tmp/release-train/alas"
            }]
          }]
        }
        """.utf8)

        let checkout = try #require(JSONDecoder.workspace.decode(WorkspaceStateFile.self, from: data).checkouts.first)

        #expect(checkout.operation == .idle)
        #expect(checkout.diagnostics.isEmpty)
        #expect(checkout.workItems.isEmpty)
        #expect(checkout.configurationSnapshot == nil)
        #expect(checkout.members.first?.availability == .pending)
        #expect(checkout.members.first?.plan == nil)
    }

    @Test func checkoutPersistsDiagnosticsWorkItemsConfigurationAndMemberPlan() throws {
        let memberID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let member = WorkspaceCheckoutMember(
            id: memberID,
            workspaceMemberID: UUID(),
            projectID: "project-a",
            fallbackProjectName: "Alas",
            fallbackRepositoryRoot: "/src/alas",
            worktreePath: "/tmp/release-train/alas",
            plan: WorkspaceCheckoutMemberPlan(
                checkoutMemberID: memberID,
                projectID: "project-a",
                destinationPath: "/tmp/release-train/alas",
                baseReference: "origin/main",
                baseCommit: "abc123",
                branchIntent: .create(atCommit: "abc123")
            )
        )
        let state = WorkspaceStateFile(checkouts: [
            WorkspaceCheckout(
                workspaceID: nil,
                fallbackWorkspaceName: "Release train",
                executionLocation: .local,
                branch: "release/1.0",
                rootPath: "/tmp/release-train",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                members: [member],
                diagnostics: [WorkspaceDiagnostic(severity: .warning, message: "Cached base ref", createdAt: capturedAt)],
                workItems: [WorkspaceWorkItemSnapshot(title: "Ship release", capturedAt: capturedAt)],
                configurationSnapshot: WorkspaceCheckoutConfigurationSnapshot(
                    capturedAt: capturedAt,
                    shared: .init(
                        sessionOpenScript: "",
                        worktreeCreateScript: "",
                        creationLaunchPreference: .init(agentID: "codex")
                    )
                )
            )
        ])

        let decoded = try JSONDecoder.workspace.decode(WorkspaceStateFile.self, from: JSONEncoder.workspace.encode(state))

        #expect(decoded == state)
    }

    @Test func legacyConfigurationSnapshotSettingsDecodeWithoutLoss() throws {
        let memberID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let data = Data("""
        {
          "capturedAt": "2023-11-14T22:13:20Z",
          "sharedSettings": { "launcher": "codex", "script": "echo shared" },
          "memberSettings": { "\(memberID.uuidString)": { "gg": "on", "setup": "echo member" } }
        }
        """.utf8)

        let snapshot = try JSONDecoder.workspace.decode(WorkspaceCheckoutConfigurationSnapshot.self, from: data)

        #expect(snapshot.sharedSettings == ["launcher": "codex", "script": "echo shared"])
        #expect(snapshot.memberSettings[memberID] == ["gg": "on", "setup": "echo member"])
    }

    @Test func checkoutOperationArchiveAndMemberAvailabilityRemainIndependent() {
        let member = WorkspaceCheckoutMember(
            id: UUID(),
            workspaceMemberID: UUID(),
            projectID: "project-a",
            fallbackProjectName: "Alas",
            fallbackRepositoryRoot: "/src/alas",
            worktreePath: "/tmp/alas",
            availability: .missing
        )
        let checkout = WorkspaceCheckout(
            id: UUID(),
            workspaceID: UUID(),
            fallbackWorkspaceName: "Release train",
            executionLocation: .local,
            branch: "release/1.0",
            rootPath: "/tmp/release-train",
            createdAt: .now,
            archivedAt: .now,
            operation: .creating,
            members: [member]
        )

        #expect(checkout.operation == .creating)
        #expect(checkout.archivedAt != nil)
        #expect(checkout.members.first?.availability == .missing)
        #expect(checkout.health == .incomplete)
    }
}
