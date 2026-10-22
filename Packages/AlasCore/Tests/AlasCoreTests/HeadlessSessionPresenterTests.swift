import Foundation
import Testing
@_spi(Testing) @_spi(AppHost) @testable import AlasCore
@_spi(Testing) @_spi(AppHost) @testable import AlasHostCore

@MainActor
struct HeadlessSessionPresenterTests {
    @Test func openAppendsAndIsIdempotent() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let id = try await fixture.storedSession()
        let presenter = fixture.presenter()

        #expect(await presenter.openSessionTab(for: id) == .success)
        #expect(await presenter.openSessionTab(for: id) == .success)
        #expect(presenter.sessionTabIndex(id, owner: fixture.owner) == 0)
    }

    @Test func closeRemovesButKeepsHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let manager = try fixture.core.sessionManager(for: fixture.worktree)
        let id = manager.createSession(agentId: "gemini").id
        await manager.flushAllPersistence()
        let presenter = fixture.presenter()
        #expect(await presenter.openSessionTab(for: id) == .success)

        #expect(await presenter.closeSessionTab(for: id) == .success)
        #expect(presenter.sessionTabIndex(id, owner: fixture.owner) == nil)
        await manager.refreshRecentNow()
        #expect(manager.sessionRows.first { $0.id == id }?.archived == false)
    }

    enum Unopenable: CaseIterable { case missing, archived }

    @Test(arguments: Unopenable.allCases)
    func openRefusesWhatCannotBeOpened(_ kind: Unopenable) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let id = kind == .missing ? "no-such-session" : try await fixture.storedSession(archived: true)
        let presenter = fixture.presenter()

        guard case .failure = await presenter.openSessionTab(for: id) else {
            Issue.record("Opened an unopenable session")
            return
        }
        #expect(presenter.sessionTabIndex(id, owner: fixture.owner) == nil)
    }

    @Test func restoreReloadsOpenSessionsAndDropsStaleOnes() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let a = try await fixture.storedSession()
        let b = try await fixture.storedSession()
        let first = fixture.presenter()
        #expect(await first.openSessionTab(for: a) == .success)
        #expect(await first.openSessionTab(for: b) == .success)
        try await fixture.persistence.setArchived(id: b, archived: true)

        let core = fixture.makeCore()
        defer { core.sessionManagers.values.forEach { $0.shutdownBackgroundTasks() } }
        let restored = fixture.presenter(core: core)
        await restored.restore()

        #expect(restored.sessionTabIndex(a, owner: fixture.owner) == 0)
        #expect(restored.sessionTabIndex(b, owner: fixture.owner) == nil)
        let file = try #require(try PersistenceStore().readIfExists(HostOpenSessionsFile.self, from: fixture.file))
        #expect(file.sessions == [fixture.worktree.id: [a]])
    }

    @Test func racingOpenAndCloseEndInTheLastRequestsState() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let id = try await fixture.storedSession()
        let presenter = fixture.presenter()

        let open = Task { await presenter.openSessionTab(for: id) }
        let close = Task { await presenter.closeSessionTab(for: id) }
        _ = await (open.value, close.value)
        #expect(presenter.sessionTabIndex(id, owner: fixture.owner) == nil)
    }

    @Test func sessionCreatedOpensTheSession() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let presenter = fixture.presenter()
        var changes = 0
        let subscription = presenter.sessionListChanges?.observe { changes += 1 }
        defer { subscription?.cancel() }

        presenter.sessionCreated("created", worktreeID: fixture.worktree.id)
        #expect(presenter.sessionTabIndex("created", owner: fixture.owner) == 0)
        #expect(changes == 1)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let projects: ProjectsManager
        let worktree: Worktree
        let core: AlasCoreContext
        var owner: SessionOwnerID { .worktree(worktree.id) }
        var file: URL { root.appendingPathComponent("host-open-sessions.json") }
        var persistence: ACPSessionPersistence { ACPSessionPersistence(path: Paths.acpSessionsDB(for: owner).path) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-presenter-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            projects = ProjectsManager(persistedProjects: [
                ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: .distantPast),
            ])
            // The presenter never reads the worktree's files, so no repository.
            let path = root.appendingPathComponent("feature")
            worktree = Worktree(
                id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
                path: path, status: .clean, lastActivity: .distantPast
            )
            projects.insertOptimisticWorktree(worktree)
            core = Self.makeCore(projects: projects, root: root)
        }

        /// Another core over the same projects, as after a host restart.
        func makeCore() -> AlasCoreContext { Self.makeCore(projects: projects, root: root) }

        private static func makeCore(projects: ProjectsManager, root: URL) -> AlasCoreContext {
            AlasCoreContext(
                projects: projects,
                runHistoryStore: nil,
                workspaceStore: WorkspaceStore(url: root.appendingPathComponent("workspaces.json")),
                attentionStore: .scratch(),
                orchestrationPersistence: ACPOrchestrationPersistence(path: root.appendingPathComponent("orchestration.sqlite").path)
            )
        }

        func presenter(core: AlasCoreContext? = nil) -> HeadlessSessionPresenter {
            HeadlessSessionPresenter(core: core ?? self.core, fileURL: file)
        }

        /// A session row in the worktree's store, written by a manager the
        /// core has not loaded.
        func storedSession(archived: Bool = false) async throws -> String {
            let manager = AlasCoreContext.defaultSessionManager(owner: owner, worktree: worktree)
            defer { manager.shutdownBackgroundTasks() }
            let id = manager.createSession(agentId: "gemini").id
            await manager.flushAllPersistence()
            if archived { try await persistence.setArchived(id: id, archived: true) }
            return id
        }

        func tearDown() {
            core.sessionManagers.values.forEach { $0.shutdownBackgroundTasks() }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
