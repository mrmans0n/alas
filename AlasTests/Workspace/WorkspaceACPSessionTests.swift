import Foundation
import Testing
@testable import Alas

@Suite("Workspace ACP session ownership")
struct WorkspaceACPSessionTests {
    @Test func checkoutOwnerUsesAnIsolatedDatabaseWhileWorktreesKeepLegacyPath() {
        let checkout = SessionOwnerID.workspaceCheckout(UUID(uuidString: "C88B61E6-4F97-4E47-A987-A4D8AC69F93D")!, .ssh("build-host"))
        #expect(Paths.acpSessionsDB(for: .worktree("legacy-worktree")) == Paths.acpSessionsDB(forWorktreeId: "legacy-worktree"))
        #expect(Paths.acpSessionsDB(for: checkout).lastPathComponent != "legacy-worktree.sqlite")
    }

    @MainActor
    @Test func checkoutManagerKeepsTypedOwnerForCreatedAndRestoredSessions() throws {
        let checkout = SessionOwnerID.workspaceCheckout(UUID(), .local)
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let manager = ACPSessionManager(
            worktreeId: "legacy-compatible-id",
            worktreePath: "/checkout",
            owner: checkout,
            store: try ACPSessionStore(path: path.path)
        )

        let session = manager.createSession(id: "checkout-session", agentId: "test")
        #expect(manager.owner == checkout)
        #expect(session.owner == checkout)
        #expect(session.worktreeId == checkout.storageKey)
    }

    @MainActor
    @Test func checkoutLaunchSpecAppliesFrozenBypassPermissionFlag() async throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"sessionCapabilities":{}}"#.utf8) }
        client.script(method: "session/new") { _ in Data(#"{"sessionId":"remote-new"}"#.utf8) }
        var capturedSpec: ACPLaunchSpec?
        var capturedHost: String?
        let manager = ACPSessionManager(
            worktreeId: "checkout",
            worktreePath: "/checkout",
            owner: .workspaceCheckout(UUID(), .ssh("checkout-host")),
            store: try ACPSessionStore(path: path.path),
            remoteHost: "checkout-host",
            setupEvaluator: { _ in .ready },
            connectionFactory: { spec, host, _ in
                capturedSpec = spec
                capturedHost = host
                return ACPConnection(client: client)
            },
            launchSpecTransformer: { spec in
                spec.agentID == "codex" ? spec.prependingArguments(["--dangerously-bypass-approvals-and-sandbox"]) : spec
            }
        )
        let session = manager.createSession(agentId: "codex")

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(capturedSpec?.arguments.first == "--dangerously-bypass-approvals-and-sandbox")
        #expect(capturedHost == "checkout-host")
        #expect(manager.remoteHost == "checkout-host")
    }

    @MainActor
    @Test func appStateCreatesCheckoutManagerAtTheFrozenRootAndKeepsMissingRootPending() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Workspace",
            executionLocation: .local,
            branch: "topic",
            rootPath: root.path,
            members: []
        )
        let state = AppState(store: MemoryStore())
        guard case let .ready(manager) = await state.workspaceACPManager(for: checkout) else {
            Issue.record("Expected checkout manager")
            return
        }
        #expect(manager.owner == .workspaceCheckout(checkout.id, .local))
        #expect(manager.worktreePath == root.path)

        let disabledTab = await state.openWorkspaceCheckoutACPSession(checkout: checkout, agentID: "test")
        #expect(disabledTab == nil)
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, .local)
        state.tabs.append(acpSession: .init(sessionId: "saved", title: "Saved"), to: owner)
        let disabledRestore = await state.restoreWorkspaceCheckoutACPSessions(checkout)
        #expect(disabledRestore == false)
        #expect(state.tabs.tabs(for: owner).count == 1)

        var unavailable = checkout
        unavailable.id = UUID()
        unavailable.rootPath = root.appendingPathComponent("missing").path
        guard case .pendingRootOrLocation = await state.workspaceACPManager(for: unavailable) else {
            Issue.record("Expected pending checkout restoration")
            return
        }
        let restored = await state.restoreWorkspaceCheckoutACPSessions(unavailable)
        #expect(restored == false)
    }

    @MainActor
    @Test func closingCheckoutACPTabDisposesTheOwnedSession() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Workspace",
            executionLocation: .local,
            branch: "topic",
            rootPath: root.path,
            members: []
        )
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, .local)
        let dbURL = Paths.acpSessionsDB(for: owner)
        defer { try? FileManager.default.removeItem(at: dbURL) }
        var detached: [(SessionOwnerID, ACPSession.ID)] = []
        let state = AppState(
            store: MemoryStore(),
            acpDetachRunner: { manager, sessionID in
                detached.append((manager.owner, sessionID))
            }
        )
        guard case let .ready(manager) = await state.workspaceACPManager(for: checkout) else {
            Issue.record("Expected checkout manager")
            return
        }
        let session = manager.createSession(id: "checkout-acp", agentId: "test")
        let tab = state.tabs.append(acpSession: .init(sessionId: session.id, title: "Checkout ACP"), to: owner)

        state.closeComposedCenterTabs(worktreeID: "member", sharedSessionOwner: owner, tabIDs: [tab.id])
        for _ in 0 ..< 20 where state.pendingACPDetachCountForTesting != 0 {
            await Task.yield()
        }

        #expect(state.tabs.tabs(for: owner).isEmpty)
        #expect(detached.map(\.0) == [owner])
        #expect(detached.map(\.1) == ["checkout-acp"])
        #expect(state.pendingACPDetachCountForTesting == 0)
    }

    @MainActor
    @Test func checkoutManagerTitleUpdatesRenameOwnerTabs() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Workspace",
            executionLocation: .local,
            branch: "topic",
            rootPath: root.path,
            members: []
        )
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, .local)
        let dbURL = Paths.acpSessionsDB(for: owner)
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let state = AppState(store: MemoryStore())
        guard case let .ready(manager) = await state.workspaceACPManager(for: checkout) else {
            Issue.record("Expected checkout manager")
            return
        }
        let session = manager.createSession(id: "checkout-title", agentId: "test")
        _ = state.tabs.append(acpSession: .init(sessionId: session.id, title: "Old Title"), to: owner)
        await manager.flushPersistence()

        let store = try ACPSessionStore(path: dbURL.path)
        #expect(try store.renameSession(id: session.id, title: "Generated Title", titleSource: .generated, updatedAt: 10))
        await manager.refreshMirror(sessionId: session.id)

        guard case let .acpSession(tabState) = state.tabs.tabs(for: owner).first else {
            Issue.record("Expected checkout ACP tab")
            return
        }
        #expect(tabState.title == "Generated Title")
    }

    @MainActor
    @Test func reloadTabsRestoresCheckoutOwnedACPManagers() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let workspaceURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json")
        let tabsDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspaceURL)
            try? FileManager.default.removeItem(at: tabsDirectory)
        }
        let checkout = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Workspace",
            executionLocation: .local,
            branch: "topic",
            rootPath: root.path,
            members: []
        )
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, .local)
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        let tabWriter = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDirectory)
        _ = tabWriter.append(acpSession: .init(sessionId: "saved-acp", title: "Saved ACP"), to: owner)
        let tabs = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDirectory)
        let workspacesManager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        let state = AppState(
            store: MemoryStore(),
            tabsManager: tabs,
            restoreActiveTabsOnStartup: false,
            workspacesManager: workspacesManager,
            workspaceStore: workspaceStore
        )
        state.config.workspacesEnabled = true

        state.reloadTabs()
        for _ in 0 ..< 40 where state.acpManager(for: owner) == nil {
            await Task.yield()
        }

        #expect(state.tabs.tabs(for: owner).count == 1)
        #expect(state.acpManager(for: owner)?.owner == owner)
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }
}
