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
            id: "worktree-\(UUID().uuidString)",
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
        #expect(state.runScriptCatalogGeneration == 1)
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
        #expect(editor.externalEditable == true)
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

    @Test func writingHelpWithoutDefaultAgentDoesNotCreateFile() throws {
        let (state, _, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        state.config.agents.worktreeAutoLaunch.agentId = nil
        state.newRunScript(scope: .repo, in: worktree)

        #expect(throws: RunScriptWritingHelpError.noDefaultAgent) {
            try state.createPendingRunScript(
                name: "Build", onExit: .keep, writingHelpRequest: "Build this project"
            )
        }
        #expect(state.pendingRunScriptCreation != nil)
        #expect(state.runScriptCatalogGeneration == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".alas/scripts/build.sh").path))

        try state.createPendingRunScript(name: "Build", onExit: .keep)
        #expect(state.pendingRunScriptCreation == nil)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".alas/scripts/build.sh").path))
    }

    @Test func writingHelpRejectsUnavailableDefaultAgent() throws {
        let (state, _, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        state.config.agents.worktreeAutoLaunch.agentId = "missing-agent"

        #expect(throws: RunScriptWritingHelpError.unsupportedAgent) {
            try state.runScriptWritingHelpAgent(in: worktree)
        }
    }

    @Test(arguments: RunScriptScope.allCases)
    func assistedCreationOpensDraftInOriginatingWorktree(scope: RunScriptScope) throws {
        let (state, _, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let agentID = try #require(ACPLaunchCatalog.specs.first?.agentID)
        state.config.agents.worktreeAutoLaunch.agentId = agentID
        state.config.agents.builtinState[agentID] = BuiltinAgentState(isEnabled: true, binaryOverride: nil)
        state.agentRegistry = AgentRegistry(
            builtinState: state.config.agents.builtinState,
            customs: [], installedIds: [agentID]
        )
        let global = root.appendingPathComponent("global")
        state.newRunScript(scope: scope, in: worktree)
        state.selectedWorktreeId = "another-worktree"

        try state.createPendingRunScript(
            name: "Build", onExit: .close, globalDir: global, writingHelpRequest: "Build the project"
        )

        #expect(state.pendingRunScriptCreation == nil)
        #expect(state.selectedWorktreeId == worktree.id)
        #expect(state.tabs.tabs(forWorktree: "another-worktree").isEmpty)
        let tabs = state.tabs.tabs(forWorktree: worktree.id)
        #expect(tabs.count == 2)
        let active = try #require(state.tabs.activeTab(forWorktree: worktree.id))
        guard case .acpSession(let chat) = active else {
            Issue.record("Expected a writing-help chat")
            return
        }
        let session = try #require(state.session(for: chat.sessionId))
        #expect(session.agentId == agentID)
        let scriptURL = (scope == .repo ? root.appendingPathComponent(".alas/scripts") : global)
            .appendingPathComponent("build.sh")
        #expect(session.composerDraft == ACPComposerDraft(segments: [.text(RunScriptWritingHelp.prompt(
            scope: scope, scriptURL: scriptURL, worktreeRoot: root, request: "Build the project"
        ))]))
        #expect(try String(contentsOf: scriptURL, encoding: .utf8).contains("# alas-on-exit: close"))
    }
}
