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

    @Test func projectScopedACPDatabaseSupportsLongWorktreePaths() throws {
        let path = "/worktrees/" + String(repeating: "nested-path-", count: 25)
        let owner = SessionOwnerID.projectWorktree(
            projectId: "12345678-1234-1234-1234-123456789abc", worktreeId: path
        )
        let other = SessionOwnerID.projectWorktree(
            projectId: "abcdefab-1234-1234-1234-123456789abc", worktreeId: path
        )
        let filename = Paths.acpSessionsDB(for: owner).lastPathComponent
        #expect(filename.utf8.count <= 240)
        #expect(filename != Paths.acpSessionsDB(for: other).lastPathComponent)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-long-acp-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ACPSessionStore(path: directory.appendingPathComponent(filename).path)
        #expect(try store.recentSessions().isEmpty)
    }
}
