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
        let manager = ACPSessionManager(
            worktreeId: "checkout",
            worktreePath: "/checkout",
            owner: .workspaceCheckout(UUID(), .local),
            store: try ACPSessionStore(path: path.path),
            setupEvaluator: { _ in .ready },
            connectionFactory: { spec, _, _ in
                capturedSpec = spec
                return ACPConnection(client: client)
            },
            launchSpecTransformer: { spec in
                spec.agentID == "codex" ? spec.prependingArguments(["--dangerously-bypass-approvals-and-sandbox"]) : spec
            }
        )
        let session = manager.createSession(agentId: "codex")

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(capturedSpec?.arguments.first == "--dangerously-bypass-approvals-and-sandbox")
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

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }
}
