import Foundation
import Testing
@testable import Alas

@Suite("Workspace terminal sessions")
struct WorkspaceTerminalSessionTests {
    private let checkoutID = UUID(uuidString: "4C7D5A7B-DFB4-40C2-8A9B-9BCB003D64F6")!

    @Test func worktreeIdentityKeepsItsExistingZmxName() {
        let identity = TerminalSessionIdentity(worktreeId: "/repos/legacy", leafId: "leaf")

        #expect(identity.zmxSessionName == ZmxSessionName.derive(worktreeId: "/repos/legacy", leafId: "leaf"))
    }

    @Test func checkoutIdentityIncludesTheCheckoutAndExecutionLocation() {
        let local = TerminalSessionIdentity(
            owner: .workspaceCheckout(checkoutID, .local), leafId: "leaf"
        )
        let remote = TerminalSessionIdentity(
            owner: .workspaceCheckout(checkoutID, .ssh("build-host")), leafId: "leaf"
        )

        #expect(local.zmxSessionName != remote.zmxSessionName)
        #expect(local.zmxSessionName.contains(checkoutID.uuidString.lowercased()))
        #expect(remote.zmxSessionName.contains(checkoutID.uuidString.lowercased()))
    }

    @Test func checkoutLaunchStartsAtRootAndPublishesOnlyCheckoutEnvironment() {
        let context = WorkspaceTerminalContext(
            checkoutID: checkoutID,
            executionLocation: .local,
            rootPath: "/work/checkout",
            branch: "feature/shared",
            manifestPath: "/work/checkout/.alas-workspace-checkout.json",
            startupScript: "echo shared-startup"
        )
        let launch = TerminalService.checkoutLaunchContext(context: context, leafID: "leaf")

        #expect(launch.owner == .workspaceCheckout(checkoutID, .local))
        #expect(launch.cwd.path == "/work/checkout")
        #expect(launch.startupScript == "echo shared-startup")
        #expect(launch.environment["ALAS_WORKSPACE_CHECKOUT_ID"] == checkoutID.uuidString.lowercased())
        #expect(launch.environment["ALAS_WORKSPACE_CHECKOUT_ROOT"] == "/work/checkout")
        #expect(launch.environment["ALAS_WORKSPACE_BRANCH"] == "feature/shared")
        #expect(launch.environment["ALAS_WORKSPACE_MANIFEST"] == "/work/checkout/.alas-workspace-checkout.json")
        #expect(launch.environment["ALAS_REPO"] == nil)
        #expect(launch.environment["ALAS_BRANCH"] == nil)
        #expect(launch.environment["ALAS_WORKTREE"] == nil)
    }

    @Test func localCheckoutTerminalInjectsCliSocketAndSessionEnvironment() throws {
        let context = WorkspaceTerminalContext(
            checkoutID: checkoutID,
            executionLocation: .local,
            rootPath: "/work/checkout",
            branch: "feature/shared",
            manifestPath: "/work/checkout/.alas-workspace-checkout.json"
        )

        let env = try TerminalService.checkoutLocalEnvironment(
            context: context,
            leafID: "leaf-1",
            inheritParent: true,
            parent: [
                "PATH": "/usr/bin:/bin",
                "ALAS_SOCKET_PATH": "/tmp/wrong.sock",
                "ALAS_SESSION_ID": "wrong",
            ],
            socketPath: "/tmp/alas.sock",
            zmxDir: "/tmp/zmx",
            cliInstaller: { URL(fileURLWithPath: "/managed/bin", isDirectory: true) }
        )

        #expect(env["ALAS_WORKSPACE_CHECKOUT_ID"] == checkoutID.uuidString.lowercased())
        #expect(env["ALAS_WORKSPACE_CHECKOUT_ROOT"] == "/work/checkout")
        #expect(env["ALAS_WORKSPACE_BRANCH"] == "feature/shared")
        #expect(env["ALAS_WORKSPACE_MANIFEST"] == "/work/checkout/.alas-workspace-checkout.json")
        #expect(env["ALAS_SESSION_ID"] == "leaf-1")
        #expect(env["ALAS_SOCKET_PATH"] == "/tmp/alas.sock")
        #expect(env["ZMX_SESSION"] == "")
        #expect(env["ZMX_DIR"] == "/tmp/zmx")
        #expect(env["PATH"] == "/managed/bin:/usr/bin:/bin")
        #expect(env["ALAS_REPO"] == nil)
        #expect(env["ALAS_WORKTREE"] == nil)
    }

    @Test func checkoutRestoreRequiresMatchingLocationAndKeepsTheValidatedCwdForRemoteLaunch() {
        let context = WorkspaceTerminalContext(
            checkoutID: checkoutID,
            executionLocation: .local,
            rootPath: "/work/checkout",
            branch: "feature/shared",
            manifestPath: "/work/checkout/.alas-workspace-checkout.json"
        )

        #expect(TerminalService.checkoutRestorationCwd(savedPath: "/work/checkout/member", context: context) == nil)
        #expect(TerminalService.checkoutRestorationCwd(savedPath: "/work/checkout/member", context: context, savedLocation: .local)?.path == "/work/checkout/member")
        #expect(TerminalService.checkoutRestorationCwd(savedPath: "/other/repo", context: context) == nil)
        #expect(TerminalService.checkoutRestorationCwd(savedPath: "/work/checkout/member", context: context, savedLocation: .ssh("build-host")) == nil)

        let remote = WorkspaceTerminalContext(
            checkoutID: checkoutID,
            executionLocation: .ssh("build-host"),
            rootPath: "/srv/checkout",
            branch: "feature/shared",
            manifestPath: "/srv/checkout/.alas-workspace-checkout.json"
        )
        #expect(TerminalService.checkoutWorkingDirectory(
            forcedCwd: URL(fileURLWithPath: "/srv/checkout/member"),
            forcedCwdLocation: .ssh("build-host"),
            context: remote
        )?.path == "/srv/checkout/member")
    }

    @MainActor
    @Test func archivingCheckoutStopsOnlyItsOwnedSessionsAndPreservesSavedTabs() async {
        let tabs = TabsManager(store: WorkspaceTerminalMemoryStore())
        let state = AppState(store: WorkspaceTerminalMemoryStore(), tabsManager: tabs)
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "feature/shared",
            rootPath: "/work/checkout",
            members: []
        )
        let owner = SessionOwnerID.workspaceCheckout(checkoutID, .local)
        let tab = tabs.appendTerminal(owner: owner, title: "Terminal", sessionId: "checkout-leaf")
        let session = TerminalSession(
            id: "checkout-leaf",
            owner: owner,
            surface: AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO()),
            executable: "/bin/zsh",
            args: []
        )
        state.terminal.registry.register(session)

        await state.stopWorkspaceCheckoutSessions(checkout)

        #expect(tabs.tabs(for: owner).map(\.id) == [tab.id])
        #expect(state.terminal.registry.session(for: "checkout-leaf") == nil)
        #expect(tab.id != "")
    }

    @MainActor
    @Test func checkoutSplitPersistsItsExecutionLocationWithTheNewLeaf() {
        let tabs = TabsManager(store: WorkspaceTerminalMemoryStore())
        let owner = SessionOwnerID.workspaceCheckout(checkoutID, .ssh("build-host"))
        let tab = tabs.appendTerminal(owner: owner, title: "Terminal", sessionId: "first")

        _ = tabs.splitFocusedLeaf(
            owner: owner,
            tabId: tab.id,
            axis: .vertical,
            newLeafId: "second",
            newSessionId: "second",
            newLeafCwdLocation: .ssh("build-host")
        )

        let leaves = tabs.tabs(for: owner).compactMap { tab -> [PaneLeaf]? in
            guard case .terminal(let state) = tab else { return nil }
            return state.root.leaves()
        }.flatMap { $0 }
        #expect(leaves.first(where: { $0.id == "second" })?.lastCwdLocation == .ssh("build-host"))
    }

    @MainActor
    @Test func initialCheckoutTerminalLeafPersistsItsExecutionLocation() {
        let tabs = TabsManager(store: WorkspaceTerminalMemoryStore())
        let owner = SessionOwnerID.workspaceCheckout(checkoutID, .ssh("build-host"))
        let tab = tabs.appendTerminal(owner: owner, title: "Terminal", sessionId: "first")

        let leaves = tabs.tabs(for: owner).compactMap { tab -> [PaneLeaf]? in
            guard case .terminal(let state) = tab else { return nil }
            return state.root.leaves()
        }.flatMap { $0 }

        #expect(tab.id != "")
        #expect(leaves.first(where: { $0.id == "first" })?.lastCwdLocation == .ssh("build-host"))
    }

    @MainActor
    @Test func manualSharedTabCloseStopsEveryCheckoutTerminalLeaf() {
        let tabs = TabsManager(store: WorkspaceTerminalMemoryStore())
        let state = AppState(store: WorkspaceTerminalMemoryStore(), tabsManager: tabs)
        let owner = SessionOwnerID.workspaceCheckout(checkoutID, .local)
        let tab = tabs.appendTerminal(owner: owner, title: "Terminal", sessionId: "first")
        _ = tabs.splitFocusedLeaf(owner: owner, tabId: tab.id, axis: .vertical, newLeafId: "second", newSessionId: "second")
        for leaf in ["first", "second"] {
            state.terminal.registry.register(TerminalSession(
                id: leaf,
                owner: owner,
                surface: AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO()),
                executable: "/bin/zsh",
                args: []
            ))
        }

        state.closeComposedCenterTabs(worktreeID: "member", sharedSessionOwner: owner, tabIDs: [tab.id])

        #expect(tabs.tabs(for: owner).isEmpty)
        #expect(state.terminal.registry.session(for: "first") == nil)
        #expect(state.terminal.registry.session(for: "second") == nil)
    }

    @MainActor
    @Test func checkoutProcessExitUsesOwnerToCloseTheLastTerminalLeaf() {
        let tabs = TabsManager(store: WorkspaceTerminalMemoryStore())
        let state = AppState(store: WorkspaceTerminalMemoryStore(), tabsManager: tabs)
        let owner = SessionOwnerID.workspaceCheckout(checkoutID, .ssh("build-host"))
        let tab = tabs.appendTerminal(owner: owner, title: "Terminal", sessionId: "leaf")
        state.terminal.registry.register(TerminalSession(
            id: "leaf",
            owner: owner,
            surface: AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO()),
            executable: "/bin/zsh",
            args: []
        ))

        state.handleTerminalProcessExited(owner: owner, leafId: "leaf", processAlive: false)

        #expect(tabs.tabs(for: owner).isEmpty)
        #expect(state.terminal.registry.session(for: "leaf") == nil)
        #expect(tab.id != "")
    }

    @MainActor
    @Test func archivingCheckoutStopsRegisteredSessionEvenWithoutPersistedTabs() async {
        let tabs = TabsManager(store: WorkspaceTerminalMemoryStore())
        let state = AppState(store: WorkspaceTerminalMemoryStore(), tabsManager: tabs)
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "feature/shared",
            rootPath: "/work/checkout",
            members: []
        )
        let owner = SessionOwnerID.workspaceCheckout(checkoutID, .local)
        state.terminal.registry.register(TerminalSession(
            id: "unpersisted-leaf",
            owner: owner,
            surface: AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO()),
            executable: "/bin/zsh",
            args: []
        ))

        await state.stopWorkspaceCheckoutSessions(checkout)

        #expect(state.terminal.registry.session(for: "unpersisted-leaf") == nil)
        #expect(tabs.tabs(for: owner).isEmpty)
    }

    @MainActor
    @Test func reloadTabsLoadsCheckoutOwnedTabsAfterWorkspaceStateLoads() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-tabs-\(UUID().uuidString).json")
        let tabsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-tabs-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: workspaceURL)
            try? FileManager.default.removeItem(at: tabsDirectory)
        }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "feature/shared",
            rootPath: "/work/checkout",
            members: []
        )
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let persistence = PersistenceStore()
        let writer = TabsManager(store: persistence, tabsDirectory: tabsDirectory)
        let saved = writer.appendTerminal(owner: owner, title: "Shared", sessionId: "checkout-leaf")
        let tabs = TabsManager(store: persistence, tabsDirectory: tabsDirectory)
        let bridge = WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore)
        let manager = WorkspacesManager(bridge: bridge)
        let state = AppState(
            store: WorkspaceTerminalMemoryStore(),
            tabsManager: tabs,
            workspaceSpacePersistenceBridge: bridge,
            workspacesManager: manager,
            workspaceStore: workspaceStore
        )
        state.config.workspacesEnabled = true

        state.reloadTabs()

        for _ in 0 ..< 40 where tabs.tabs(for: owner).isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(tabs.tabs(for: owner).map(\.id) == [saved.id])
        #expect(tabs.activeTabId(for: owner) == saved.id)
    }
}

private final class WorkspaceTerminalMemoryStore: PersistenceStoreProtocol {
    func read<T>(_ type: T.Type, from url: URL) throws -> T where T: Decodable { throw CocoaError(.fileNoSuchFile) }
    func readIfExists<T>(_ type: T.Type, from url: URL) throws -> T? where T: Decodable { nil }
    func write<T>(_ value: T, to url: URL) throws where T: Encodable {}
}
