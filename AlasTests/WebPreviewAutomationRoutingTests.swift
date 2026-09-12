import Foundation
import Testing
import WebKit
@testable import Alas

@MainActor
struct WebPreviewAutomationRoutingTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @Test func sessionOwnerWinsOverDifferentCwd() async {
        let worktree = Worktree(id: "b", projectId: "p", name: "b", branch: "b",
                                path: URL(fileURLWithPath: "/b"), status: .clean, lastActivity: .now)
        let checkout = SessionOwnerID.workspaceCheckout(UUID(), .ssh("devbox"))
        var routed: SessionOwnerID?
        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in nil }, sessionOwner: { $0 == "s" ? checkout : nil },
            originatingWorktree: { _ in worktree }, visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in }, openExternalFile: { _, _ in },
            previewCommand: { _, owner, _ in routed = owner
            return .ok }, activateApp: {}
        )
        let response = await router.handle(.init(version: 1, sessionId: "s", cwd: "/b", command: .preview(.init(action: .list))))
        #expect(response == .ok)
        #expect(routed == checkout)
        let stale = await router.handle(.init(version: 1, sessionId: "closed", cwd: "/b", command: .preview(.init(action: .list))))
        guard case .error = stale else { Issue.record("Unknown session must not use cwd")
        return }
    }

    @Test func listIsOwnerScopedAndDoesNotLoadPageOrFocus() async throws {
        let tabs = TabsManager(store: MemoryStore())
        let owner = SessionOwnerID.workspaceCheckout(UUID(), .local)
        _ = tabs.openWebPreview(owner: owner, url: URL(string: "https://example.com"))
        _ = tabs.openWebPreview(worktreeId: "other")
        let service = WebPreviewAutomationService(
            tabs: tabs, owner: owner, isAuthorized: { true },
            resolveOpen: { _ in throw WebPreviewAutomationError.unavailable },
            focus: { _ in Issue.record("Listing cannot focus UI") }
        )
        let result = try await service.perform(.init(action: .list))
        let previews = try #require(result["previews"] as? [[String: Any]])
        #expect(previews.count == 1)
        #expect(previews.first?["owner_key"] as? String == owner.storageKey)
        #expect(tabs.webPreviewBrowser(ownerKey: owner.storageKey, remoteHost: nil).webView.url == nil)
        tabs.closeAll(worktreeId: owner.storageKey)
        tabs.closeAll(worktreeId: "other")
    }

    @Test func closedAndReopenedPreviewRejectsOldHandle() async throws {
        let tabs = TabsManager(store: MemoryStore())
        let owner = SessionOwnerID.worktree("owner")
        _ = tabs.openWebPreview(owner: owner)
        let old = tabs.webPreviewBrowser(ownerKey: owner.storageKey, remoteHost: nil)
        tabs.closeAll(worktreeId: owner.storageKey)
        _ = tabs.openWebPreview(owner: owner)
        defer { tabs.closeAll(worktreeId: owner.storageKey) }
        let service = WebPreviewAutomationService(
            tabs: tabs, owner: owner, isAuthorized: { true },
            resolveOpen: { _ in throw WebPreviewAutomationError.unavailable }, focus: { _ in }
        )
        await #expect(throws: WebPreviewAutomationError.self) {
            try await service.perform(.init(action: .console, previewID: old.automationID))
        }
        #expect(old.isClosed)
    }

    @Test func revokedAuthorizationDuringEndpointLookupDoesNotOpenTab() async {
        let tabs = TabsManager(store: MemoryStore())
        var allowed = true
        let service = WebPreviewAutomationService(
            tabs: tabs, owner: .worktree("owner"), isAuthorized: { allowed },
            resolveOpen: { _ in
                await Task.yield()
                allowed = false
                return .init(url: URL(string: "https://example.com"), remoteHost: nil)
            }, focus: { _ in Issue.record("Revoked caller cannot focus") }
        )
        await #expect(throws: WebPreviewAutomationError.self) { try await service.perform(.init(action: .open)) }
        #expect(tabs.tabs(forWorktree: "owner").isEmpty)
    }

    @Test func remoteLoopbackEndpointDoesNotCreateBrowser() async {
        let tabs = TabsManager(store: MemoryStore())
        let service = WebPreviewAutomationService(
            tabs: tabs, owner: .worktree("remote"), isAuthorized: { true },
            resolveOpen: { _ in .init(url: URL(string: "http://127.0.0.1:3000"), remoteHost: "devbox") },
            focus: { _ in Issue.record("Blocked endpoint cannot focus") }
        )
        await #expect(throws: WebPreviewAutomationError.self) { try await service.perform(.init(action: .open)) }
        #expect(tabs.tabs(forWorktree: "remote").isEmpty)
    }

    @Test func busyOpenDoesNotChangePersistedURLOrBrowserHost() async throws {
        let tabs = TabsManager(store: MemoryStore())
        let owner = SessionOwnerID.worktree("busy-owner")
        let originalURL = URL(string: "https://example.com/original")!
        let tab = tabs.openWebPreview(owner: owner, url: originalURL)
        let browser = tabs.webPreviewBrowser(ownerKey: owner.storageKey, remoteHost: nil)
        let operation = try browser.automationState.begin()
        defer {
            browser.automationState.finish(operation)
            tabs.closeAll(worktreeId: owner.storageKey)
        }
        let service = WebPreviewAutomationService(
            tabs: tabs, owner: owner, isAuthorized: { true },
            resolveOpen: { _ in .init(url: URL(string: "https://example.com/replacement"), remoteHost: "devbox") },
            focus: { _ in Issue.record("Busy open must not focus") }, resolveHost: { _ in ["192.0.2.1"] }
        )
        await #expect(throws: WebPreviewBrowserAutomationError.self) {
            try await service.perform(.init(action: .open, url: "https://example.com/replacement"))
        }
        #expect(tabs.tabs(for: owner) == [tab])
        #expect(!browser.isClosed)
        #expect(browser.webView.url == nil)
    }

    @Test func backgroundNavigationPersistsURLWithoutActivatingPreview() throws {
        let tabs = TabsManager(store: MemoryStore())
        let owner = SessionOwnerID.worktree("background-owner")
        _ = tabs.openWebPreview(owner: owner)
        let browser = tabs.webPreviewBrowser(ownerKey: owner.storageKey, remoteHost: nil)
        let other = tabs.appendTerminal(worktreeId: owner.storageKey, title: "Shell", sessionId: "shell")
        defer { tabs.closeAll(worktreeId: owner.storageKey) }
        let url = URL(string: "https://example.com/changed")!
        browser.onNavigate?(url)
        let preview = try #require(tabs.tabs(for: owner).compactMap { tab -> WebPreviewTabState? in
            guard case .webPreview(let state) = tab else { return nil }
            return state
        }.first)
        #expect(preview.url == url)
        #expect(tabs.activeTabId(forWorktree: owner.storageKey) == other.id)
    }

    @Test func remoteDNSAliasIsRejectedBeforeTabCreation() async {
        let tabs = TabsManager(store: MemoryStore())
        let service = WebPreviewAutomationService(
            tabs: tabs, owner: .worktree("remote"), isAuthorized: { true },
            resolveOpen: { _ in .init(url: URL(string: "http://local-alias:3000"), remoteHost: "devbox") },
            focus: { _ in Issue.record("Blocked endpoint cannot focus") }, resolveHost: { _ in ["127.0.0.1"] }
        )
        await #expect(throws: WebPreviewAutomationError.self) { try await service.perform(.init(action: .open)) }
        #expect(tabs.tabs(forWorktree: "remote").isEmpty)
    }
}
