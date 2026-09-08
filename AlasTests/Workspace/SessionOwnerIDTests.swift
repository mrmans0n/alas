import Foundation
import Testing
@testable import Alas

struct SessionOwnerIDTests {
    @Test func worktreeOwnerKeepsLegacyStorageKey() {
        let owner = SessionOwnerID.worktree("worktree/path")

        #expect(owner.storageKey == "worktree/path")
        #expect(Paths.tabsFile(for: owner) == Paths.tabsFile(forWorktreeId: "worktree/path"))
    }

    @Test func checkoutOwnersAtDifferentLocationsHaveDifferentKeys() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let local = SessionOwnerID.workspaceCheckout(id, .local)
        let remote = SessionOwnerID.workspaceCheckout(id, .ssh("build-host"))

        #expect(local.storageKey != remote.storageKey)
        #expect(Paths.tabsFile(for: local) != Paths.tabsFile(for: remote))
    }

    @Test func worktreeCannotAliasCheckoutOwnerEvenWhenStorageKeysMatch() {
        let checkout = SessionOwnerID.workspaceCheckout(UUID(), .local)

        #expect(SessionOwnerID.worktree(checkout.storageKey) != checkout)
    }
}
