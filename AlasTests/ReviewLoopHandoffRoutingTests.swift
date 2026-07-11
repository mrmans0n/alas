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

    @Test func handoffReusesActiveACPChatWithEmptyComposer() async throws {
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

    @Test func handoffOpensNewACPChatWhenActiveComposerHasText() async throws {
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

    @Test func handoffOpensNewACPChatWhenActiveComposerHasWhitespaceOnlyText() async throws {
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
        try await seedPersistedSession(id: restoredSessionId, worktreeId: worktreeId, draft: persistedDraft)
        let existing = ACPSessionTabState(sessionId: restoredSessionId, title: "Restored")
        state.tabs.append(acpSession: existing, to: worktreeId)

        state.openACPHandoff(agentID: "test-agent", initialPrompt: "Review feedback")

        let tabs = acpTabs(in: state)
        #expect(tabs.count == 2)
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
        await manager.refreshRecentNow()
        let restoredSession = try #require(manager.placeholderSession(id: restoredSessionId))
        #expect(restoredSession.hydrationState == .loading)
        let newTab = try #require(tabs.last)
        #expect(newTab.id != existing.id)
        #expect(sessionFor(tab: newTab, in: state)?.composerDraft == ACPComposerDraft(segments: [.text("Review feedback")]))

        await manager.hydrateIfNeeded(id: restoredSessionId)
        #expect(restoredSession.composerDraft == persistedDraft)
    }

    @Test func handoffOpensNewACPChatWhenActiveSessionHasTranscriptHistory() async throws {
        let state = makeState()
        state.openNewACPSession(agentID: "test-agent")
        let existing = try #require(acpTabs(in: state).first)
        let worktreeId = try #require(state.selectedWorktreeId)
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
        let existingSession = try #require(manager.placeholderSession(id: existing.sessionId))
        existingSession.recordUserPrompt(text: "Previous prompt", attachments: [])

        state.openACPHandoff(agentID: "test-agent", initialPrompt: "Review feedback")

        let tabs = acpTabs(in: state)
        #expect(tabs.count == 2)
        #expect(sessionFor(tab: existing, in: state)?.transcript.messages.count == 1)
        let newTab = try #require(tabs.last)
        #expect(newTab.id != existing.id)
        #expect(sessionFor(tab: newTab, in: state)?.composerDraft == ACPComposerDraft(segments: [.text("Review feedback")]))
        #expect(state.tabs.activeTabId(forWorktree: worktreeId) == newTab.id)
    }

    @Test func handoffOpensNewACPChatWhenActiveSessionHasQueuedPrompt() async throws {
        let state = makeState()
        state.openNewACPSession(agentID: "test-agent")
        let existing = try #require(acpTabs(in: state).first)
        let worktreeId = try #require(state.selectedWorktreeId)
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
        let existingSession = try #require(manager.placeholderSession(id: existing.sessionId))
        existingSession.enqueue(blocks: [.text("Queued prompt")])

        state.openACPHandoff(agentID: "test-agent", initialPrompt: "Review feedback")

        let tabs = acpTabs(in: state)
        #expect(tabs.count == 2)
        #expect(sessionFor(tab: existing, in: state)?.queue.count == 1)
        let newTab = try #require(tabs.last)
        #expect(newTab.id != existing.id)
        #expect(sessionFor(tab: newTab, in: state)?.composerDraft == ACPComposerDraft(segments: [.text("Review feedback")]))
        #expect(state.tabs.activeTabId(forWorktree: worktreeId) == newTab.id)
    }

    @Test func handoffOpensNewACPChatWhenActiveSessionUsesDifferentAgent() async throws {
        let state = makeState()
        state.openNewACPSession(agentID: "other-agent")
        let existing = try #require(acpTabs(in: state).first)
        let worktreeId = try #require(state.selectedWorktreeId)

        state.openACPHandoff(agentID: "test-agent", initialPrompt: "Review feedback")

        let tabs = acpTabs(in: state)
        #expect(tabs.count == 2)
        #expect(sessionFor(tab: existing, in: state)?.composerDraft == .empty)
        let newTab = try #require(tabs.last)
        #expect(newTab.id != existing.id)
        let newSession = try #require(sessionFor(tab: newTab, in: state))
        #expect(newSession.agentId == "test-agent")
        #expect(newSession.composerDraft == ACPComposerDraft(segments: [.text("Review feedback")]))
        #expect(state.tabs.activeTabId(forWorktree: worktreeId) == newTab.id)
    }

    @Test func handoffOpensNewACPChatWhenActiveSessionIsMirror() async throws {
        let state = makeState()
        state.openNewACPSession(agentID: "test-agent")
        let existing = try #require(acpTabs(in: state).first)
        let worktreeId = try #require(state.selectedWorktreeId)
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
        await manager.flushPersistence()
        let mirrorOwner = ACPSessionManager(
            worktreeId: worktreeId,
            worktreePath: "/tmp/mirror-owner",
            store: try ACPSessionStore(path: Paths.acpSessionsDB(forWorktreeId: worktreeId).path),
            instanceId: "mirror-owner",
            pid: Int64(getpid())
        )
        #expect(await mirrorOwner.acquireWriterLease(sessionId: existing.sessionId))
        #expect(!(await manager.acquireWriterLease(sessionId: existing.sessionId)))
        #expect(manager.isMirror(sessionId: existing.sessionId))

        state.openACPHandoff(agentID: "test-agent", initialPrompt: "Review feedback")

        let tabs = acpTabs(in: state)
        #expect(tabs.count == 2)
        #expect(sessionFor(tab: existing, in: state)?.composerDraft == .empty)
        let newTab = try #require(tabs.last)
        #expect(newTab.id != existing.id)
        #expect(sessionFor(tab: newTab, in: state)?.composerDraft == ACPComposerDraft(segments: [.text("Review feedback")]))
        #expect(state.tabs.activeTabId(forWorktree: worktreeId) == newTab.id)

        await mirrorOwner.releaseWriterLease(sessionId: existing.sessionId)
    }

    @Test func handoffOpensNewACPChatWhenNoActiveACPChatExists() async throws {
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
                AgentDefinition(
                    id: "other-agent",
                    displayName: "Other Agent",
                    binary: "other-agent",
                    binaryOverride: nil,
                    promptModeArgs: [],
                    bypassPermissionsFlag: nil,
                    extraTerminalArgs: nil,
                    isBuiltin: false,
                    isEnabled: true,
                    builtinLogoAssetName: nil
                ),
            ],
            installedIds: ["test-agent", "other-agent"]
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

    private func seedPersistedSession(id: String, worktreeId: String, draft: ACPComposerDraft) async throws {
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
