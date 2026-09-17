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

    @Test func newRepoScriptDetectsStacksAtWorktreeRoot() throws {
        let (state, _, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Cargo.toml"))

        state.newRunScript(scope: .repo, in: worktree)
        #expect(state.pendingRunScriptCreation?.detectedStacks.map(\.stack) == [.cargo])

        state.newRunScript(scope: .global, in: worktree)
        #expect(state.pendingRunScriptCreation?.detectedStacks.isEmpty == true)
    }

    @Test func bundleCreationWritesCheckedScriptsAndOpensTheFirst() throws {
        let (state, _, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        state.newRunScript(scope: .repo, in: worktree)
        let actions = RunScriptStackCatalog.actions(for: .rails).filter { ["build", "dev", "test"].contains($0.id) }

        try state.createPendingRunScripts(stack: .rails, actions: actions)

        #expect(state.pendingRunScriptCreation == nil)
        #expect(state.runScriptCatalogGeneration == 1)
        let scriptsDir = root.appendingPathComponent(".alas/scripts")
        let dev = try String(contentsOf: scriptsDir.appendingPathComponent("rails-dev.sh"), encoding: .utf8)
        #expect(dev.contains("# alas-name: Dev server (Rails)"))
        #expect(dev.contains("# alas-on-exit: keep"))
        #expect(dev.contains("# alas-url: http://localhost:3000"))
        #expect(dev.hasSuffix("set -euo pipefail\n\nbin/rails server\n"))
        let test = try String(contentsOf: scriptsDir.appendingPathComponent("rails-test.sh"), encoding: .utf8)
        #expect(test.contains("# alas-on-exit: close"))
        #expect(!test.contains("alas-url"))
        #expect(test.hasSuffix("bin/rails test\n"))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: scriptsDir.appendingPathComponent("rails-test.sh").path
        )[.posixPermissions] as? Int
        #expect(permissions == 0o755)
        let tab = try #require(state.tabs.activeTab(forWorktree: worktree.id))
        guard case .editor(let editor) = tab else {
            Issue.record("expected repo editor tab")
            return
        }
        #expect(editor.relativePath == ".alas/scripts/rails-dev.sh")
    }

    @Test func bundleCreationNamespacesFilenamesByStackToAvoidCrossStackCollisions() throws {
        let (state, _, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        state.newRunScript(scope: .repo, in: worktree)
        let cargoBuild = RunScriptStackCatalog.actions(for: .cargo).filter { $0.id == "build" }
        try state.createPendingRunScripts(stack: .cargo, actions: cargoBuild)

        state.newRunScript(scope: .repo, in: worktree)
        let jsBuild = RunScriptStackCatalog.actions(for: .javascript).filter { $0.id == "build" }
        try state.createPendingRunScripts(stack: .javascript, actions: jsBuild)

        let scriptsDir = root.appendingPathComponent(".alas/scripts")
        #expect(try String(contentsOf: scriptsDir.appendingPathComponent("cargo-build.sh"), encoding: .utf8).contains("cargo build"))
        #expect(try String(contentsOf: scriptsDir.appendingPathComponent("javascript-build.sh"), encoding: .utf8).contains("npm run build"))
    }

    @Test func bundleCreationLeavesExistingScriptsAlone() throws {
        let (state, _, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptsDir = root.appendingPathComponent(".alas/scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try Data("#!/bin/zsh\necho mine\n".utf8).write(to: scriptsDir.appendingPathComponent("cargo-build.sh"))
        state.newRunScript(scope: .repo, in: worktree)
        let actions = RunScriptStackCatalog.actions(for: .cargo).filter { ["build", "test"].contains($0.id) }

        try state.createPendingRunScripts(stack: .cargo, actions: actions)

        #expect(try String(contentsOf: scriptsDir.appendingPathComponent("cargo-build.sh"), encoding: .utf8) == "#!/bin/zsh\necho mine\n")
        #expect(FileManager.default.fileExists(atPath: scriptsDir.appendingPathComponent("cargo-test.sh").path))
        let tab = try #require(state.tabs.activeTab(forWorktree: worktree.id))
        guard case .editor(let editor) = tab else {
            Issue.record("expected repo editor tab")
            return
        }
        #expect(editor.relativePath == ".alas/scripts/cargo-test.sh")
    }

    @Test func bundleCreationWithNothingNewKeepsDialogOpen() throws {
        let (state, _, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptsDir = root.appendingPathComponent(".alas/scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try Data().write(to: scriptsDir.appendingPathComponent("cargo-build.sh"))
        state.newRunScript(scope: .repo, in: worktree)
        let actions = RunScriptStackCatalog.actions(for: .cargo).filter { $0.id == "build" }

        #expect(throws: RunScriptCreationError.allScriptsExist) {
            try state.createPendingRunScripts(stack: .cargo, actions: actions)
        }
        #expect(throws: RunScriptCreationError.emptySelection) {
            try state.createPendingRunScripts(stack: .cargo, actions: [])
        }
        #expect(state.pendingRunScriptCreation != nil)
        #expect(state.runScriptCatalogGeneration == 0)
        #expect(state.tabs.activeTab(forWorktree: worktree.id) == nil)
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
        let (state, project, _, root) = try fixture()
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

    @Test func repositoryDefaultIsScopedAndUsedForWritingHelp() throws {
        let (state, project, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let agentID = try #require(ACPLaunchCatalog.specs.first?.agentID)
        state.config.agents.worktreeAutoLaunch.agentId = "global-agent"
        state.agentRegistry = AgentRegistry(
            builtinState: [agentID: BuiltinAgentState(isEnabled: true, binaryOverride: nil)],
            customs: [], installedIds: [agentID]
        )
        var scripts = ProjectStartupScripts.defaults
        scripts.agentSelection = .agent(agentID)
        state.updateProject(id: project.id, name: project.name, icon: project.icon, startupScripts: scripts, mcpServers: [])

        let worktreeRoot = URL(fileURLWithPath: project.path, isDirectory: true)
        #expect(state.defaultAgentID(projectId: project.id, worktreeRoot: worktreeRoot) == agentID)
        #expect(state.defaultAgentID(projectId: "another-project", worktreeRoot: worktreeRoot) == "global-agent")
        #expect(try state.runScriptWritingHelpAgent(in: worktree) == agentID)

        scripts.agentSelection = .none
        state.updateProject(id: project.id, name: project.name, icon: project.icon, startupScripts: scripts, mcpServers: [])
        #expect(throws: RunScriptWritingHelpError.noDefaultAgent) {
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
