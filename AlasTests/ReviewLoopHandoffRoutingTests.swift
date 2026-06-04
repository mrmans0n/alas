import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct ReviewLoopHandoffRoutingTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        let projectsFile: ProjectsFile

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            if type == ProjectsFile.self {
                return projectsFile as? T
            }
            if type == AppConfig.self {
                return AppConfig.defaults as? T
            }
            return nil
        }
    }

    @Test func handoffReusesActiveACPChatWithEmptyComposer() throws {
        let state = makeState()
        state.openNewACPSession(agentID: "test-agent")
        let initialTabs = acpTabs(in: state)
        let existing = try #require(initialTabs.first)

        state.openACPHandoff(agentID: "test-agent", initialPrompt: "Review feedback")

        let tabs = acpTabs(in: state)
        #expect(tabs.count == 1)
        #expect(tabs.first?.id == existing.id)
        let session = try #require(sessionFor(tab: existing, in: state))
        #expect(session.composerDraft == ACPComposerDraft(segments: [.text("Review feedback")]))
        let worktreeId = try #require(state.selectedWorktreeId)
        #expect(state.tabs.activeTabId(forWorktree: worktreeId) == existing.id)
    }

    @Test func handoffOpensNewACPChatWhenActiveComposerHasText() throws {
        let state = makeState()
        state.openNewACPSession(agentID: "test-agent")
        let existing = try #require(acpTabs(in: state).first)
        let worktreeId = try #require(state.selectedWorktreeId)
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
        let existingSession = try #require(manager.placeholderSession(id: existing.sessionId))
        manager.persistComposerDraft(ACPComposerDraft(segments: [.text("Existing draft")]), for: existingSession)

        state.openACPHandoff(agentID: "test-agent", initialPrompt: "Review feedback")

        let tabs = acpTabs(in: state)
        #expect(tabs.count == 2)
        #expect(sessionFor(tab: existing, in: state)?.composerDraft == ACPComposerDraft(segments: [.text("Existing draft")]))
        let newTab = try #require(tabs.last)
        #expect(newTab.id != existing.id)
        #expect(sessionFor(tab: newTab, in: state)?.composerDraft == ACPComposerDraft(segments: [.text("Review feedback")]))
        #expect(state.tabs.activeTabId(forWorktree: worktreeId) == newTab.id)
    }

    @Test func handoffOpensNewACPChatWhenActiveComposerHasWhitespaceOnlyText() throws {
        let state = makeState()
        state.openNewACPSession(agentID: "test-agent")
        let existing = try #require(acpTabs(in: state).first)
        let worktreeId = try #require(state.selectedWorktreeId)
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
        let existingSession = try #require(manager.placeholderSession(id: existing.sessionId))
        let whitespaceDraft = ACPComposerDraft(segments: [.text(" \n\t")])
        manager.persistComposerDraft(whitespaceDraft, for: existingSession)

        state.openACPHandoff(agentID: "test-agent", initialPrompt: "Review feedback")

        let tabs = acpTabs(in: state)
        #expect(tabs.count == 2)
        #expect(sessionFor(tab: existing, in: state)?.composerDraft == whitespaceDraft)
        let newTab = try #require(tabs.last)
        #expect(newTab.id != existing.id)
        #expect(sessionFor(tab: newTab, in: state)?.composerDraft == ACPComposerDraft(segments: [.text("Review feedback")]))
        #expect(state.tabs.activeTabId(forWorktree: worktreeId) == newTab.id)
    }

    @Test func handoffOpensNewACPChatWhenActiveRestoredSessionHasNotHydrated() async throws {
        let state = makeState()
        let worktreeId = try #require(state.selectedWorktreeId)
        let restoredSessionId = "restored-\(UUID().uuidString)"
        let persistedDraft = ACPComposerDraft(segments: [.text("Persisted draft")])
        try seedPersistedSession(id: restoredSessionId, worktreeId: worktreeId, draft: persistedDraft)
        let existing = ACPSessionTabState(sessionId: restoredSessionId, title: "Restored")
        state.tabs.append(acpSession: existing, to: worktreeId)

        state.openACPHandoff(agentID: "test-agent", initialPrompt: "Review feedback")

        let tabs = acpTabs(in: state)
        #expect(tabs.count == 2)
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
        let restoredSession = try #require(manager.placeholderSession(id: restoredSessionId))
        #expect(restoredSession.hydrationState == .loading)
        let newTab = try #require(tabs.last)
        #expect(newTab.id != existing.id)
        #expect(sessionFor(tab: newTab, in: state)?.composerDraft == ACPComposerDraft(segments: [.text("Review feedback")]))

        await manager.hydrateIfNeeded(id: restoredSessionId)
        #expect(restoredSession.composerDraft == persistedDraft)
    }

    @Test func handoffOpensNewACPChatWhenNoActiveACPChatExists() throws {
        let state = makeState()

        state.openACPHandoff(agentID: "test-agent", initialPrompt: "Review feedback")

        let tabs = acpTabs(in: state)
        let newTab = try #require(tabs.first)
        #expect(tabs.count == 1)
        #expect(sessionFor(tab: newTab, in: state)?.composerDraft == ACPComposerDraft(segments: [.text("Review feedback")]))
    }

    private func makeState() -> AppState {
        let project = ProjectConfig(
            id: UUID().uuidString,
            name: "Project",
            path: "/tmp/project-\(UUID().uuidString)",
            color: "blue",
            addedAt: Date()
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project])))
        let worktree = Worktree(
            id: UUID().uuidString,
            projectId: project.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: project.path),
            status: .clean,
            lastActivity: Date()
        )
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.selectedWorktreeId = worktree.id
        state.config.changes.aiToolId = "test-agent"
        state.agentRegistry = AgentRegistry(
            builtinState: [:],
            customs: [
                AgentDefinition(
                    id: "test-agent",
                    displayName: "Test Agent",
                    binary: "test-agent",
                    binaryOverride: nil,
                    promptModeArgs: [],
                    bypassPermissionsFlag: nil,
                    extraTerminalArgs: nil,
                    isBuiltin: false,
                    isEnabled: true,
                    builtinLogoAssetName: nil
                ),
            ],
            installedIds: ["test-agent"]
        )
        return state
    }

    private func acpTabs(in state: AppState) -> [ACPSessionTabState] {
        guard let worktreeId = state.selectedWorktreeId else { return [] }
        return state.tabs.tabs(forWorktree: worktreeId).compactMap { tab in
            if case .acpSession(let tabState) = tab {
                return tabState
            }
            return nil
        }
    }

    private func sessionFor(tab: ACPSessionTabState, in state: AppState) -> ACPSession? {
        guard let worktreeId = state.selectedWorktreeId else { return nil }
        return state.acpManager(forWorktreeId: worktreeId)?.placeholderSession(id: tab.sessionId)
    }

    private func seedPersistedSession(id: String, worktreeId: String, draft: ACPComposerDraft) throws {
        let storeURL = Paths.acpSessionsDB(forWorktreeId: worktreeId)
        try? FileManager.default.removeItem(at: storeURL)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = try ACPSessionStore(path: storeURL.path)
        try store.upsertSession(.init(
            id: id,
            agentId: "test-agent",
            title: "Restored",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        ))
        try store.upsertComposerDraft(sessionId: id, draft: draft, updatedAt: 1)
    }
}
