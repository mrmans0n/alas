import Foundation
import Testing
@testable import Alas

@MainActor
struct OwnerTabsManagerTests {
    @Test func checkoutOwnerPersistsTerminalTabsIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = SessionOwnerID.workspaceCheckout(UUID(), .ssh("build-host"))
        let manager = TabsManager(store: PersistenceStore(), tabsDirectory: directory)
        let tab = manager.appendTerminal(owner: owner, title: "Shared", sessionId: "shared")

        #expect(manager.tabs(for: owner).map(\.id) == [tab.id])
        #expect(manager.tabs(forWorktree: "member").isEmpty)

        let reloaded = TabsManager(store: PersistenceStore(), tabsDirectory: directory)
        reloaded.load(owner: owner)
        #expect(reloaded.tabs(for: owner).map(\.id) == [tab.id])
        #expect(reloaded.activeTabId(for: owner) == tab.id)
    }

    @Test func closingAndArchivingCheckoutOwnerDoNotTouchWorktreeTabs() {
        let owner = SessionOwnerID.workspaceCheckout(UUID(), .local)
        let manager = TabsManager(store: OwnerTabsMemoryStore())
        let shared = manager.appendTerminal(owner: owner, title: "Shared", sessionId: "shared")
        let local = manager.appendTerminal(worktreeId: "member", title: "Member", sessionId: "member")

        manager.close(owner: owner, tabId: shared.id)
        #expect(manager.tabs(for: owner).isEmpty)
        #expect(manager.tabs(forWorktree: "member").map(\.id) == [local.id])

        manager.archive(owner: owner)
        #expect(manager.tabs(forWorktree: "member").map(\.id) == [local.id])
    }

    @Test func appStateRoutesComposedTabsToTheirActualOwners() {
        let manager = TabsManager(store: OwnerTabsMemoryStore())
        let state = AppState(store: OwnerTabsMemoryStore(), tabsManager: manager)
        let owner = SessionOwnerID.workspaceCheckout(UUID(), .local)
        let shared = manager.appendTerminal(owner: owner, title: "Shared", sessionId: "shared")
        let member = Tab.editor(.init(id: "member-editor", title: "Member", relativePath: "Member.swift"))
        manager.restore(
            tab: member,
            worktreeID: "member",
            placement: .init(previousID: nil, nextID: nil, ordinal: 0)
        )

        let composition = state.centerTabComposition(
            focusedWorktreeID: "member",
            sharedSessionOwner: owner
        )
        #expect(composition.tabs.map(\.id) == [shared.id, member.id])
        #expect(composition.activeId == shared.id)

        state.activateComposedCenterTab(worktreeID: "member", sharedSessionOwner: owner, tabID: member.id)
        #expect(manager.activeTabId(forWorktree: "member") == member.id)
        #expect(manager.activeTabId(for: owner) == nil)

        state.closeComposedCenterTabs(worktreeID: "member", sharedSessionOwner: owner, tabIDs: [shared.id])
        #expect(manager.tabs(for: owner).isEmpty)
        #expect(manager.tabs(forWorktree: "member").map(\.id) == [member.id])
    }

    @Test func composedMemberCloseUsesExistingClosedTabLifecycle() {
        let manager = TabsManager(store: OwnerTabsMemoryStore())
        let state = AppState(store: OwnerTabsMemoryStore(), tabsManager: manager)
        let owner = SessionOwnerID.workspaceCheckout(UUID(), .local)
        let member = Tab.editor(.init(id: "member-editor", title: "Member", relativePath: "Member.swift"))
        manager.restore(
            tab: member,
            worktreeID: "member",
            placement: .init(previousID: nil, nextID: nil, ordinal: 0)
        )

        state.requestCloseComposedCenterTab(
            worktreeID: "member",
            sharedSessionOwner: owner,
            tabID: member.id
        )

        #expect(manager.tabs(forWorktree: "member").isEmpty)
        #expect(state.canReopenClosedTab)
    }
}

private final class OwnerTabsMemoryStore: PersistenceStoreProtocol {
    func read<T>(_ type: T.Type, from url: URL) throws -> T where T: Decodable { throw CocoaError(.fileNoSuchFile) }
    func readIfExists<T>(_ type: T.Type, from url: URL) throws -> T? where T: Decodable { nil }
    func write<T>(_ value: T, to url: URL) throws where T: Encodable {}
}
