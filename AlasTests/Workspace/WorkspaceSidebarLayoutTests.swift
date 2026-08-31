import Foundation
import Testing
@testable import Alas

struct WorkspaceSidebarLayoutTests {
    @Test func fullTreeKeepsProjectsAndWorkspacesAsOrderedPeers() {
        let workspaceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let workspace = Workspace(id: workspaceID, name: "Release", executionLocation: .local, members: [])
        let checkout = WorkspaceCheckout(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!, workspaceID: workspaceID,
            fallbackWorkspaceName: "Release", executionLocation: .local, branch: "release", rootPath: "/tmp/release", members: []
        )

        let rows = WorkspaceSidebarLayout.rows(
            members: [.project("project-a"), .workspace(workspaceID)],
            workspaces: [workspace], checkouts: [checkout]
        )

        #expect(rows == [.project("project-a"), .workspace(workspaceID), .checkout(checkout.id)])
    }

    @Test func archivedCheckoutsRemainSelectableForUnarchive() {
        let workspaceID = UUID()
        let workspace = Workspace(id: workspaceID, name: "Release", executionLocation: .local, members: [])
        let archived = WorkspaceCheckout(workspaceID: workspaceID, fallbackWorkspaceName: "Release", executionLocation: .local, branch: "release", rootPath: "/tmp/release", archivedAt: .now, members: [])

        let rows = WorkspaceSidebarLayout.rows(members: [.workspace(workspaceID)], workspaces: [workspace], checkouts: [archived])

        #expect(rows == [.workspace(workspaceID), .checkout(archived.id)])
    }

    @Test func formerWorkspaceCheckoutsRemainReachableAfterDefinitionDeletion() {
        let former = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Former Workspace",
            executionLocation: .local,
            branch: "release",
            rootPath: "/tmp/release",
            members: []
        )

        let rows = WorkspaceSidebarLayout.rows(members: [], workspaces: [], checkouts: [former])

        #expect(rows == [.formerWorkspace, .checkout(former.id)])
    }

    @Test func visibleCheckoutIDsIgnoreWorkspaceCheckoutsFromOtherSpaces() {
        let visibleWorkspaceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let hiddenWorkspaceID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let visibleWorkspace = Workspace(id: visibleWorkspaceID, name: "Visible", executionLocation: .local, members: [])
        let hiddenWorkspace = Workspace(id: hiddenWorkspaceID, name: "Hidden", executionLocation: .local, members: [])
        let visibleCheckout = WorkspaceCheckout(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            workspaceID: visibleWorkspaceID,
            fallbackWorkspaceName: "Visible",
            executionLocation: .local,
            branch: "visible",
            rootPath: "/tmp/visible",
            members: []
        )
        let hiddenCheckout = WorkspaceCheckout(
            id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            workspaceID: hiddenWorkspaceID,
            fallbackWorkspaceName: "Hidden",
            executionLocation: .local,
            branch: "hidden",
            rootPath: "/tmp/hidden",
            members: []
        )

        let ids = WorkspaceSidebarLayout.visibleCheckoutIDs(
            members: [.workspace(visibleWorkspaceID)],
            workspaces: [visibleWorkspace, hiddenWorkspace],
            checkouts: [hiddenCheckout, visibleCheckout]
        )

        #expect(ids == [visibleCheckout.id])
    }
}
