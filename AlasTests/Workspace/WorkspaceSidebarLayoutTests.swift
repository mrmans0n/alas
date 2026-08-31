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
}
