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
            remoteAdapterResolver: { _, _, _ in
                .ready(.init(adapterPath: "/tmp/claude-agent-acp", nodeBinDirectory: ""))
            },
            connectionFactory: { spec, host, _ in
                capturedSpec = spec
                capturedHost = host
                return ACPConnection(client: client)
            },
            launchSpecTransformer: { spec in
                spec.agentID == "claude" ? spec.prependingArguments(["--dangerously-bypass-approvals-and-sandbox"]) : spec
            }
        )
        let session = manager.createSession(agentId: "claude")

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
        try writeManifest(for: checkout)
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
        try writeManifest(for: checkout)
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
        try writeManifest(for: checkout)
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
    @Test func openingCheckoutACPSessionRejectsStaleArchivedSnapshots() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let workspaceURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspaceURL)
        }
        let stale = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Workspace",
            executionLocation: .local,
            branch: "topic",
            rootPath: root.path,
            members: []
        )
        var archived = stale
        archived.archivedAt = Date(timeIntervalSince1970: 1)
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        try await workspaceStore.checkpoint(.init(checkouts: [archived]))
        let workspacesManager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        let state = AppState(
            store: MemoryStore(),
            workspacesManager: workspacesManager,
            workspaceStore: workspaceStore
        )
        state.config.workspacesEnabled = true
        _ = await workspacesManager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))

        let tab = await state.openWorkspaceCheckoutACPSession(checkout: stale, agentID: "test")

        #expect(tab == nil)
        #expect(state.acpManager(for: SessionOwnerID.workspaceCheckout(stale.id, .local)) == nil)
    }

    @MainActor
    @Test func restoringCheckoutACPRevalidatesAfterRemoteLocationProbe() async throws {
        let workspaceURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json")
        let tabsDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: workspaceURL)
            try? FileManager.default.removeItem(at: tabsDirectory)
        }
        let checkout = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Workspace",
            executionLocation: .ssh("checkout-host"),
            branch: "topic",
            rootPath: "/srv/checkouts/topic",
            members: []
        )
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        let tabs = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDirectory)
        _ = tabs.append(acpSession: .init(sessionId: "saved-acp", title: "Saved ACP"), to: owner)
        let workspacesManager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        let state = AppState(
            store: MemoryStore(),
            tabsManager: tabs,
            restoreActiveTabsOnStartup: false,
            workspacesManager: workspacesManager,
            workspaceStore: workspaceStore,
            workspaceRemoteTransport: .init(runner: { _, _, _ in
                try await workspaceStore.mutate { file in
                    guard let index = file.checkouts.firstIndex(where: { $0.id == checkout.id }) else { return }
                    file.checkouts[index].archivedAt = Date(timeIntervalSince1970: 1)
                    file.checkouts[index].operation = .archiving
                }
                return .init(exitCode: 0, stdout: "/srv/checkouts/topic\n", stderr: "")
            })
        )
        state.config.workspacesEnabled = true
        _ = await workspacesManager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))

        let restored = await state.restoreWorkspaceCheckoutACPSessions(checkout)

        #expect(restored == false)
        #expect(state.acpManager(for: owner) == nil)
    }

    @MainActor
    @Test func openingCheckoutACPRevalidatesAfterRemoteLocationProbe() async throws {
        let workspaceURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let checkout = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Workspace",
            executionLocation: .ssh("checkout-host"),
            branch: "topic",
            rootPath: "/srv/checkouts/topic",
            members: []
        )
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        let workspacesManager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        let state = AppState(
            store: MemoryStore(),
            workspacesManager: workspacesManager,
            workspaceStore: workspaceStore,
            workspaceRemoteTransport: .init(runner: { _, _, _ in
                try await workspaceStore.mutate { file in
                    guard let index = file.checkouts.firstIndex(where: { $0.id == checkout.id }) else { return }
                    file.checkouts[index].archivedAt = Date(timeIntervalSince1970: 1)
                    file.checkouts[index].operation = .archiving
                }
                return .init(exitCode: 0, stdout: "/srv/checkouts/topic\n", stderr: "")
            })
        )
        state.config.workspacesEnabled = true
        _ = await workspacesManager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))

        let tab = await state.openWorkspaceCheckoutACPSession(checkout: checkout, agentID: "test")

        #expect(tab == nil)
        #expect(state.acpManager(for: owner) == nil)
        #expect(state.tabs.tabs(for: owner).isEmpty)
    }

    @MainActor
    @Test func checkoutACPManagerRequiresManifestRootOwnership() async throws {
        let claimedRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let replacedRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: claimedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacedRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: claimedRoot)
            try? FileManager.default.removeItem(at: replacedRoot)
        }
        let checkoutID = UUID()
        let original = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Workspace",
            executionLocation: .local,
            branch: "topic",
            rootPath: claimedRoot.path,
            members: []
        )
        try writeManifest(for: original)
        try FileManager.default.copyItem(
            at: claimedRoot.appendingPathComponent(WorkspaceCheckoutManifest.fileName),
            to: replacedRoot.appendingPathComponent(WorkspaceCheckoutManifest.fileName)
        )
        let replaced = WorkspaceCheckout(
            id: checkoutID,
            workspaceID: nil,
            fallbackWorkspaceName: "Workspace",
            executionLocation: .local,
            branch: "topic",
            rootPath: replacedRoot.path,
            members: []
        )
        let state = AppState(store: MemoryStore())

        guard case .pendingRootOrLocation = await state.workspaceACPManager(for: replaced) else {
            Issue.record("Expected copied manifest with a different root to stay pending")
            return
        }
        #expect(state.acpManager(for: SessionOwnerID.workspaceCheckout(replaced.id, .local)) == nil)
    }

    @MainActor
    @Test func concurrentRemoteCheckoutACPManagerRequestsReuseTheFirstManagerAfterProbe() async throws {
        let checkout = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Workspace",
            executionLocation: .ssh("checkout-host"),
            branch: "topic",
            rootPath: "/srv/checkouts/topic",
            members: []
        )
        let runner = CountingRemoteProbeRunner()
        let state = AppState(
            store: MemoryStore(),
            workspaceRemoteTransport: .init(runner: { executable, args, timeout in
                await runner.run(executable: executable, args: args, timeout: timeout)
            })
        )

        async let first = state.workspaceACPManager(for: checkout)
        async let second = state.workspaceACPManager(for: checkout)

        guard case let .ready(firstManager) = await first,
              case let .ready(secondManager) = await second
        else {
            Issue.record("Expected both manager requests to resolve")
            return
        }
        #expect(firstManager === secondManager)
        #expect(await runner.callCount == 4)
        #expect(state.acpManager(for: SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)) === firstManager)
    }

    @MainActor
    @Test func openingExistingCheckoutACPSessionUsesTheOwnerBucket() async throws {
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
        try writeManifest(for: checkout)
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, .local)
        let dbURL = Paths.acpSessionsDB(for: owner)
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let state = AppState(store: MemoryStore())
        guard case let .ready(manager) = await state.workspaceACPManager(for: checkout) else {
            Issue.record("Expected checkout manager")
            return
        }
        let session = manager.createSession(id: "checkout-existing", agentId: "test")
        manager.persistComposerDraft(.init(segments: [.text("draft")]), for: session)
        await manager.flushPersistence()

        await state.openExistingACPSession(sessionId: session.id, owner: owner)

        #expect(state.tabs.tabs(for: owner).compactMap { tab -> ACPSession.ID? in
            guard case let .acpSession(state) = tab else { return nil }
            return state.sessionId
        } == [session.id])
        #expect(state.tabs.tabs(forWorktree: "member-worktree").isEmpty)
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
        try writeManifest(for: checkout)
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
        for _ in 0 ..< 100 where state.acpManager(for: owner) == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(state.tabs.tabs(for: owner).count == 1)
        #expect(state.acpManager(for: owner)?.owner == owner)
    }

    @MainActor
    @Test func unarchiveRestoresCheckoutOwnedACPManagerForRetainedTabs() async throws {
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
            archivedAt: Date(timeIntervalSince1970: 1),
            members: []
        )
        try writeManifest(for: checkout)
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
        _ = await workspacesManager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))

        _ = try await state.unarchiveWorkspaceCheckout(id: checkout.id)

        #expect(state.tabs.tabs(for: owner).count == 1)
        #expect(state.acpManager(for: owner)?.owner == owner)
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private func writeManifest(for checkout: WorkspaceCheckout) throws {
        let manifest = WorkspaceCheckoutManifest(
            checkoutID: checkout.id,
            rootPath: checkout.rootPath,
            branch: checkout.branch,
            members: checkout.members.map {
                .init(id: $0.id, projectID: $0.projectID, path: $0.worktreePath, availability: $0.availability)
            }
        )
        let url = URL(fileURLWithPath: checkout.rootPath).appendingPathComponent(WorkspaceCheckoutManifest.fileName)
        try JSONEncoder().encode(manifest).write(to: url)
    }
}

private actor CountingRemoteProbeRunner {
    private(set) var callCount = 0

    func run(executable _: String, args _: [String], timeout _: TimeInterval) async -> ProcessResult {
        callCount += 1
        try? await Task.sleep(nanoseconds: 25_000_000)
        return .init(exitCode: 0, stdout: "/srv/checkouts/topic\n", stderr: "")
    }
}
