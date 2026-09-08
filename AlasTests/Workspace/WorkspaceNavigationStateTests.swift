import Foundation
import Testing
@testable import Alas

struct WorkspaceNavigationStateTests {
    @Test func checkoutRestoresLastAvailableFocusedMember() {
        let checkout = fixtureCheckout(members: [availableMember, unavailableMember])
        var state = WorkspaceNavigationState()

        state.selectMember(availableMember.id, in: checkout, resolvedWorktreeIDs: [availableMember.id: "/tmp/a"])
        state.selectCheckout(checkout, resolvedWorktreeIDs: [availableMember.id: "/tmp/a"])

        #expect(state.selectedCheckoutID == checkout.id)
        #expect(state.focusedCheckoutMemberID == availableMember.id)
        #expect(state.repositoryFocusWorktreeID == "/tmp/a")
    }

    @Test func checkoutDefaultsToFirstAvailableMember() {
        let checkout = fixtureCheckout(members: [unavailableMember, availableMember])
        var state = WorkspaceNavigationState()

        state.selectCheckout(checkout, resolvedWorktreeIDs: [availableMember.id: "/tmp/a"])

        #expect(state.focusedCheckoutMemberID == availableMember.id)
        #expect(state.repositoryFocusWorktreeID == "/tmp/a")
    }

    @Test func unavailableFocusedMemberFallsForwardWithOneWrap() {
        let first = unavailableMember
        let second = availableMember
        let third = member(id: "33333333-3333-3333-3333-333333333333", availability: .available)
        let checkout = fixtureCheckout(members: [first, second, third])
        var state = WorkspaceNavigationState(
            selectedWorkspaceID: nil,
            selectedCheckoutID: checkout.id,
            focusedCheckoutMemberID: third.id
        )

        state.selectCheckout(checkout, resolvedWorktreeIDs: [second.id: "/tmp/b"])

        #expect(state.focusedCheckoutMemberID == second.id)
        #expect(state.repositoryFocusWorktreeID == "/tmp/b")
    }

    @Test func checkoutWithNoAvailableMembersLeavesRepositoryFocusUnavailable() {
        let checkout = fixtureCheckout(members: [unavailableMember])
        var state = WorkspaceNavigationState()

        state.selectCheckout(checkout, resolvedWorktreeIDs: [:])

        #expect(state.selectedCheckoutID == checkout.id)
        #expect(state.focusedCheckoutMemberID == nil)
        #expect(state.repositoryFocusWorktreeID == nil)
    }

    @Test func resolvedWorktreeDoesNotMakeAnUnavailableMemberFocusable() {
        let checkout = fixtureCheckout(members: [unavailableMember, availableMember])
        var state = WorkspaceNavigationState()

        state.selectCheckout(checkout, resolvedWorktreeIDs: [
            unavailableMember.id: "/tmp/stale",
            availableMember.id: "/tmp/available"
        ])

        #expect(state.focusedCheckoutMemberID == availableMember.id)
        #expect(state.repositoryFocusWorktreeID == "/tmp/available")
    }

    @Test func archiveRemovesSelectedCheckoutAndRepositoryFocus() {
        let checkout = fixtureCheckout(members: [availableMember])
        var state = WorkspaceNavigationState(
            selectedWorkspaceID: nil,
            selectedCheckoutID: checkout.id,
            focusedCheckoutMemberID: availableMember.id,
            repositoryFocusWorktreeID: "/tmp/a"
        )

        state.removeCheckout(checkout.id)

        #expect(state.selectedCheckoutID == nil)
        #expect(state.focusedCheckoutMemberID == nil)
        #expect(state.repositoryFocusWorktreeID == nil)
    }

    @Test func samePathWorktreeFromAnotherProjectDoesNotResolveTheMember() {
        let checkout = fixtureCheckout(members: [availableMember])
        let wrongProject = Worktree(
            id: "/tmp/project", projectId: "other-project", name: "main", branch: "main",
            path: URL(fileURLWithPath: "/tmp/project"), status: .clean, lastActivity: .distantPast
        )

        let ids = WorkspaceMemberWorktreeResolver.resolvedWorktreeIDs(checkout: checkout, worktrees: [wrongProject])

        #expect(ids.isEmpty)
    }

    private let availableMember = member(id: "11111111-1111-1111-1111-111111111111", availability: .available)
    private let unavailableMember = member(id: "22222222-2222-2222-2222-222222222222", availability: .missing)

    private static func member(id: String, availability: WorkspaceCheckoutMemberAvailability) -> WorkspaceCheckoutMember {
        WorkspaceCheckoutMember(
            id: UUID(uuidString: id)!, workspaceMemberID: UUID(), projectID: "project",
            fallbackProjectName: "Project", fallbackRepositoryRoot: "/tmp/project", worktreePath: "/tmp/project",
            availability: availability
        )
    }

    private func member(id: String, availability: WorkspaceCheckoutMemberAvailability) -> WorkspaceCheckoutMember {
        Self.member(id: id, availability: availability)
    }

    private func fixtureCheckout(members: [WorkspaceCheckoutMember]) -> WorkspaceCheckout {
        WorkspaceCheckout(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, workspaceID: nil,
            fallbackWorkspaceName: "Workspace", executionLocation: .local, branch: "main", rootPath: "/tmp", members: members
        )
    }
}
