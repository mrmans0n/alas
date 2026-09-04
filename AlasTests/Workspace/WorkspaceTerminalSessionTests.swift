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
        ) == nil)
        #expect(TerminalService.checkoutWorkingDirectory(
            forcedCwd: URL(fileURLWithPath: "/srv/checkout/member"),
            forcedCwdLocation: .ssh("build-host"),
            context: remote,
            remoteCwdAlreadyValidated: true
        )?.path == "/srv/checkout/member")
        #expect(TerminalService.checkoutWorkingDirectory(
            forcedCwd: URL(fileURLWithPath: "/srv/checkout/member"),
            forcedCwdLocation: .ssh("other-host"),
            context: remote,
            remoteCwdAlreadyValidated: true
        ) == nil)
    }

    @Test func checkoutRestoreRejectsSymlinkedLocalCwdOutsideTheFrozenRoot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-terminal-symlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("checkout", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("member", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let context = WorkspaceTerminalContext(
            checkoutID: checkoutID,
            executionLocation: .local,
            rootPath: root.path,
            branch: "feature/shared",
            manifestPath: root.appendingPathComponent(".alas-workspace-checkout.json").path
        )

        #expect(TerminalService.checkoutRestorationCwd(savedPath: link.path, context: context, savedLocation: .local) == nil)
    }

    @Test func remoteCheckoutCwdContainmentRejectsSymlinkEscapes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-terminal-remote-cwd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("checkout", isDirectory: true)
        let inside = root.appendingPathComponent("member", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let accepted = try await Process.run(
            "/bin/sh",
            args: ["-c", AppState.remoteCheckoutCwdContainmentCommand(rootPath: root.path, savedPath: inside.path)]
        )
        #expect(accepted.exitCode == 0)

        let rejected = try await Process.run(
            "/bin/sh",
            args: ["-c", AppState.remoteCheckoutCwdContainmentCommand(rootPath: root.path, savedPath: link.path)]
        )
        #expect(rejected.exitCode != 0)
    }

    @MainActor
    @Test func checkoutTerminalLaunchUsesAuthoritativeOperationState() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-terminal-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let staleCheckout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "feature/shared",
            rootPath: "/work/checkout",
            operation: .idle,
            members: []
        )
        var authoritative = staleCheckout
        authoritative.operation = .archiving
        try await workspaceStore.checkpoint(.init(checkouts: [authoritative]))
        let state = AppState(
            store: WorkspaceTerminalMemoryStore(),
            tabsManager: TabsManager(store: WorkspaceTerminalMemoryStore()),
            workspaceStore: workspaceStore
        )
        state.config.workspacesEnabled = true

        await #expect(throws: (any Error).self) {
            try await state.openWorkspaceCheckoutTerminalTab(staleCheckout)
        }
        await #expect(throws: (any Error).self) {
            try await state.openWorkspaceCheckoutAgentTerminalTab(
                staleCheckout,
                focusedMemberWorktree: Worktree(
                    id: "member",
                    projectId: "project",
                    name: "main",
                    branch: "main",
                    path: URL(fileURLWithPath: "/work/checkout/member"),
                    status: .clean,
                    lastActivity: .distantPast
                ),
                agentId: "agent"
            )
        }
    }

    @MainActor
    @Test func checkoutTerminalLaunchRequiresMatchingManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-terminal-root-\(UUID().uuidString)")
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-terminal-manifest-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspaceURL)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "feature/shared",
            rootPath: root.path,
            operation: .idle,
            members: []
        )
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        let tabs = TabsManager(store: WorkspaceTerminalMemoryStore())
        let state = AppState(
            store: WorkspaceTerminalMemoryStore(),
            tabsManager: tabs,
            workspaceStore: workspaceStore
        )
        state.config.workspacesEnabled = true

        await #expect(throws: (any Error).self) {
            try await state.openWorkspaceCheckoutTerminalTab(checkout)
        }
        #expect(tabs.tabs(for: SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)).isEmpty)
    }

    @MainActor
    @Test func checkoutAgentLaunchRejectsWorktreeOutsideFrozenMemberSet() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-agent-root-\(UUID().uuidString)")
        let memberPath = root.appendingPathComponent("member")
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-agent-guard-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspaceURL)
        }
        try FileManager.default.createDirectory(at: memberPath, withIntermediateDirectories: true)
        let checkoutMemberID = UUID()
        let member = WorkspaceCheckoutMember(
            id: checkoutMemberID,
            workspaceMemberID: UUID(),
            projectID: "project-a",
            fallbackProjectName: "Project A",
            fallbackRepositoryRoot: memberPath.path,
            worktreePath: memberPath.path,
            availability: .available,
            checkpoint: .setupComplete
        )
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "feature/shared",
            rootPath: root.path,
            operation: .idle,
            members: [member]
        )
        let manifest = WorkspaceCheckoutManifest(
            checkoutID: checkout.id,
            rootPath: checkout.rootPath,
            branch: checkout.branch,
            members: [.init(id: member.id, projectID: member.projectID, path: member.worktreePath, availability: member.availability)]
        )
        try JSONEncoder().encode(manifest)
            .write(to: root.appendingPathComponent(WorkspaceCheckoutManifest.fileName))
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        let wrongProject = ProjectConfig(
            id: "project-b",
            name: "Project B",
            path: memberPath.path,
            color: "#000000",
            addedAt: .distantPast,
            cachedWorktrees: []
        )
        let tabs = TabsManager(store: WorkspaceTerminalMemoryStore())
        let state = AppState(
            store: WorkspaceTerminalMemoryStore(projectsFile: .init(projects: [wrongProject])),
            tabsManager: tabs,
            workspaceStore: workspaceStore
        )
        state.config.workspacesEnabled = true
        state.agentRegistry = AgentRegistry(
            builtinState: [:],
            customs: [AgentDefinition(
                id: "test-agent",
                displayName: "Test Agent",
                binary: "test-agent",
                binaryOverride: nil,
                promptModeArgs: ["-p"],
                bypassPermissionsFlag: nil,
                extraTerminalArgs: nil,
                isBuiltin: false,
                isEnabled: true,
                builtinLogoAssetName: nil
            )],
            installedIds: ["test-agent"]
        )
        let wrongProjectWorktree = Worktree(
            id: "wrong",
            projectId: "project-b",
            name: "main",
            branch: "main",
            path: memberPath,
            status: .clean,
            lastActivity: .distantPast
        )

        await #expect(throws: AppState.AgentTerminalLaunchError.projectUnavailable) {
            try await state.openWorkspaceCheckoutAgentTerminalTab(
                checkout,
                focusedMemberWorktree: wrongProjectWorktree,
                agentId: "test-agent"
            )
        }
        #expect(tabs.tabs(for: SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)).isEmpty)
    }

    @MainActor
    @Test func archivingCheckoutStopsItsOwnedSessionsAndArchivesSavedTabs() async {
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

        #expect(tabs.tabs(for: owner).isEmpty)
        #expect(state.terminal.registry.session(for: "checkout-leaf") == nil)
        #expect(tab.id != "")
    }

    @MainActor
    @Test func checkoutStopperIncludesPersistedTerminalLeavesWithoutLiveSessions() {
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
        let tab = tabs.appendTerminal(owner: owner, title: "Terminal", sessionId: "first")
        _ = tabs.splitFocusedLeaf(
            owner: owner,
            tabId: tab.id,
            axis: .vertical,
            newLeafId: "second",
            newSessionId: "second"
        )

        let persisted = state.persistedWorkspaceCheckoutTerminalSessionsForTesting(checkout)

        #expect(Set(persisted.map(\.leafId)) == ["first", "second"])
        #expect(persisted.allSatisfy { $0.owner == owner })
    }

    @MainActor
    @Test func harnessLookupIncludesPersistedCheckoutTerminalLeaves() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-terminal-harness-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let workspaceID = UUID()
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: workspaceID,
            fallbackWorkspaceName: "Shared",
            executionLocation: .ssh("devbox"),
            branch: "feature/shared",
            rootPath: "/work/checkout",
            members: []
        )
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        let bridge = WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore)
        let manager = WorkspacesManager(bridge: bridge)
        _ = await manager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "space", spaces: [
            SpaceConfig(id: "space", name: "Default", emoji: "folder", projectIds: [], lastSelectedWorktreeId: nil, createdAt: .distantPast)
        ]))
        let tabs = TabsManager(store: WorkspaceTerminalMemoryStore())
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        _ = tabs.appendTerminal(owner: owner, title: "Shared", sessionId: "checkout-leaf")
        let state = AppState(
            store: WorkspaceTerminalMemoryStore(),
            tabsManager: tabs,
            workspacesManager: manager,
            workspaceStore: workspaceStore
        )

        let lookup = try #require(state.persistedLeafLocation(leafId: "checkout-leaf"))
        #expect(lookup.projectId == workspaceID.uuidString)
        #expect(lookup.worktreeId == owner.storageKey)
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
    @Test func archivedCheckoutOwnerKeepsPrefixButContributesNoKnownLeavesToStartupSweep() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-archived-sweep-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "feature/shared",
            rootPath: "/work/checkout",
            archivedAt: Date(timeIntervalSince1970: 10),
            members: []
        )
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        let bridge = WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore)
        let manager = WorkspacesManager(bridge: bridge)
        _ = await manager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "space", spaces: [
            SpaceConfig(id: "space", name: "Default", emoji: "folder", projectIds: [], lastSelectedWorktreeId: nil, createdAt: .distantPast)
        ]))
        let tabs = TabsManager(store: WorkspaceTerminalMemoryStore())
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        _ = tabs.appendTerminal(owner: owner, title: "Shared", sessionId: "retained-leaf")
        let state = AppState(
            store: WorkspaceTerminalMemoryStore(),
            tabsManager: tabs,
            workspacesManager: manager,
            workspaceStore: workspaceStore
        )

        #expect(state.workspaceCheckoutTerminalLeafIDsByOwner()[owner] == [])
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

    @MainActor
    @Test func checkoutTerminalRestoreUsesAuthoritativeOperationState() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-tabs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        var checkout = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "feature/shared",
            rootPath: "/work/checkout",
            members: []
        )
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        let bridge = WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore)
        let manager = WorkspacesManager(bridge: bridge)
        _ = await manager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "space", spaces: [
            SpaceConfig(id: "space", name: "Default", emoji: "folder", projectIds: [], lastSelectedWorktreeId: nil, createdAt: .distantPast)
        ]))
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let tabs = TabsManager(store: WorkspaceTerminalMemoryStore())
        let tab = tabs.appendTerminal(owner: owner, title: "Shared", sessionId: "checkout-leaf")
        let state = AppState(
            store: WorkspaceTerminalMemoryStore(),
            tabsManager: tabs,
            workspacesManager: manager,
            workspaceStore: workspaceStore
        )
        checkout.operation = .archiving
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))

        let restored = try await state.restoreTerminalTabIfNeededAsync(owner: owner, tabId: tab.id)

        #expect(restored == nil)
        #expect(state.terminal.registry.session(for: "checkout-leaf") == nil)
        #expect(tabs.tabs(for: owner).map(\.id) == [tab.id])
    }
}

private final class WorkspaceTerminalMemoryStore: PersistenceStoreProtocol {
    private let projectsFile: ProjectsFile

    init(projectsFile: ProjectsFile = .init(projects: [])) {
        self.projectsFile = projectsFile
    }

    func read<T>(_ type: T.Type, from url: URL) throws -> T where T: Decodable { throw CocoaError(.fileNoSuchFile) }
    func readIfExists<T>(_ type: T.Type, from url: URL) throws -> T? where T: Decodable {
        if type == ProjectsFile.self { return projectsFile as? T }
        return nil
    }
    func write<T>(_ value: T, to url: URL) throws where T: Encodable {}
}
