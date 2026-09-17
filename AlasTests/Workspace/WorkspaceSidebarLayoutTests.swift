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

struct WorkspaceCheckoutWorktreeResolverTests {
    @Test func resolvesExactProjectAndCanonicalPathMatch() throws {
        let worktree = makeWorktree(projectID: "project-a", path: "/tmp/workspace/repo")
        let matching = makeCheckout(
            name: "Release",
            members: [.init(
                workspaceMemberID: UUID(),
                projectID: "project-a",
                fallbackProjectName: "Repo",
                fallbackRepositoryRoot: "/tmp/repo",
                worktreePath: "/tmp/workspace/./repo",
                availability: .available
            )]
        )
        let differentProject = makeCheckout(
            name: "Other",
            members: [.init(
                workspaceMemberID: UUID(),
                projectID: "project-b",
                fallbackProjectName: "Repo",
                fallbackRepositoryRoot: "/tmp/repo",
                worktreePath: "/tmp/workspace/repo",
                availability: .available
            )]
        )

        let presentation = try #require(WorkspaceCheckoutWorktreeResolver.presentation(
            for: worktree,
            checkouts: [differentProject, matching]
        ))

        #expect(presentation == .init(name: "Release", state: .active))
    }

    @Test func prefersActiveCheckoutOverNewerArchivedMatch() throws {
        let worktree = makeWorktree()
        let archived = makeCheckout(name: "Archived", createdAt: .now, archivedAt: .now)
        let active = makeCheckout(name: "Active", createdAt: .distantPast)

        let presentation = try #require(WorkspaceCheckoutWorktreeResolver.presentation(
            for: worktree,
            checkouts: [archived, active]
        ))

        #expect(presentation == .init(name: "Active", state: .active))
    }

    @Test func showsFormerWorkspaceUsingPersistedName() throws {
        let worktree = makeWorktree()
        let former = makeCheckout(
            name: "Former Release",
            workspaceID: nil,
            members: [makeMember()]
        )

        let presentation = try #require(WorkspaceCheckoutWorktreeResolver.presentation(
            for: worktree,
            checkouts: [former]
        ))

        #expect(presentation == .init(name: "Former Release", state: .formerWorkspace))

        #expect(presentation.accessibilityLabel == "Former workspace checkout: Former Release")
    }

    @Test func distinguishesArchivedWorkspaceFromFormerWorkspace() throws {
        let archived = makeCheckout(name: "Archived Release", archivedAt: .now)

        let presentation = try #require(WorkspaceCheckoutWorktreeResolver.presentation(
            for: makeWorktree(),
            checkouts: [archived]
        ))

        #expect(presentation == .init(name: "Archived Release", state: .archived))
        #expect(presentation.accessibilityLabel == "Archived workspace checkout: Archived Release")
    }

    @Test func ignoresUnavailableCheckoutMember() {
        let unavailable = makeCheckout(members: [makeMember(availability: .identityConflict)])

        #expect(WorkspaceCheckoutWorktreeResolver.presentation(
            for: makeWorktree(),
            checkouts: [unavailable]
        ) == nil)
    }

    @Test func returnsNoPresentationForUnlinkedWorktree() {
        let worktree = makeWorktree(path: "/tmp/other")

        #expect(WorkspaceCheckoutWorktreeResolver.presentation(
            for: worktree,
            checkouts: [makeCheckout()]
        ) == nil)
    }

    private func makeWorktree(
        projectID: String = "project-a",
        path: String = "/tmp/workspace/repo"
    ) -> Worktree {
        .init(
            id: path,
            projectId: projectID,
            name: "feature",
            branch: "feature",
            path: URL(fileURLWithPath: path),
            status: .clean,
            lastActivity: .now
        )
    }

    private func makeCheckout(
        name: String = "Release",
        workspaceID: UUID? = UUID(),
        createdAt: Date = .now,
        archivedAt: Date? = nil,
        members: [WorkspaceCheckoutMember]? = nil
    ) -> WorkspaceCheckout {
        .init(
            workspaceID: workspaceID,
            fallbackWorkspaceName: name,
            executionLocation: .local,
            branch: "feature",
            rootPath: "/tmp/workspace",
            createdAt: createdAt,
            archivedAt: archivedAt,
            members: members ?? [makeMember()]
        )
    }

    private func makeMember(
        availability: WorkspaceCheckoutMemberAvailability = .available
    ) -> WorkspaceCheckoutMember {
        .init(
            workspaceMemberID: UUID(),
            projectID: "project-a",
            fallbackProjectName: "Repo",
            fallbackRepositoryRoot: "/tmp/repo",
            worktreePath: "/tmp/workspace/repo",
            availability: availability
        )
    }
}
