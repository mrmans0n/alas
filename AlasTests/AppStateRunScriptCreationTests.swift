import Foundation
import Testing
@testable import Alas

@MainActor
struct AppStateRunScriptCreationTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private func fixture() throws -> (AppState, ProjectConfig, Worktree, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = ProjectConfig(
            id: "project",
            name: "Alas",
            path: root.path,
            color: "blue",
            addedAt: Date()
        )
        let worktree = Worktree(
            id: "worktree",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: root,
            status: .clean,
            lastActivity: Date()
        )
        let state = AppState(store: MemoryStore())
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        return (state, project, worktree, root)
    }

    @Test func newScriptRecordsPendingPresentation() throws {
        let (state, project, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        state.newRunScript(scope: .repo, in: worktree)

        #expect(state.pendingRunScriptCreation?.scope == .repo)
        #expect(state.pendingRunScriptCreation?.projectId == project.id)
        #expect(state.pendingRunScriptCreation?.worktreeId == worktree.id)
        #expect(state.pendingRunScriptCreation?.repositoryName == project.name)
    }

    @Test func repoCreationWritesAndOpensRelativeEditor() throws {
        let (state, _, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        state.newRunScript(scope: .repo, in: worktree)

        try state.createPendingRunScript(name: " Dev Server ", onExit: .close)

        #expect(state.pendingRunScriptCreation == nil)
        let tab = try #require(state.tabs.activeTab(forWorktree: worktree.id))
        guard case .editor(let editor) = tab else {
            Issue.record("expected repo editor tab")
            return
        }
        #expect(editor.relativePath == ".alas/scripts/dev-server.sh")
        #expect(!editor.isExternal)
    }

    @Test func globalCreationUsesInjectedDirectoryAndOpensExternalEditor() throws {
        let (state, _, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("global", isDirectory: true)
        state.newRunScript(scope: .global, in: worktree)

        try state.createPendingRunScript(
            name: "Build",
            onExit: .keep,
            globalDir: global
        )

        let tab = try #require(state.tabs.activeTab(forWorktree: worktree.id))
        guard case .editor(let editor) = tab else {
            Issue.record("expected global editor tab")
            return
        }
        #expect(editor.externalAbsolutePath == global.appendingPathComponent("build.sh").path)
        #expect(editor.externalEditable)
    }

    @Test func failurePreservesPendingPresentation() throws {
        let (state, project, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        state.pendingRunScriptCreation = RunScriptCreationPresentation(
            scope: .repo,
            projectId: project.id,
            worktreeId: "missing",
            repositoryName: project.name
        )

        #expect(throws: RunScriptCreationError.worktreeUnavailable) {
            try state.createPendingRunScript(name: "Build", onExit: .keep)
        }
        #expect(state.pendingRunScriptCreation != nil)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".alas/scripts/build.sh").path
        ))
    }
}
