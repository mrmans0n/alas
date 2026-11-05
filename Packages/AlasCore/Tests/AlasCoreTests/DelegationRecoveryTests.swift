import Foundation
import Testing
@_spi(AppHost) @testable import AlasCore
@_spi(AppHost) @testable import AlasHostCore

@MainActor
struct DelegationRecoveryTests {
    /// A delegation the host stopped in the middle of setting up, whose
    /// worktree never appeared, fails instead of staying in setup forever.
    @Test func setupInterruptedBeforeItsWorktreeExistedFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ACPOrchestrationPersistence(path: root.appendingPathComponent("orchestration.sqlite").path)
        try await persistence.insert(ACPDelegationRecord(
            childSessionId: "child", parentSessionId: "parent", projectId: "p",
            parentWorktreeId: "parent-worktree", childWorktreeId: nil, agentId: "codex",
            worktreeRequest: .new(branch: "feature", base: "main", destinationPath: root.appendingPathComponent("feature").path, optimisticId: "feature"),
            pendingInitialPrompt: "Go", phase: .creatingWorktree, failureMessage: nil, createdAt: 1, updatedAt: 1
        ))
        let core = AlasCoreContext(
            projects: ProjectsManager(persistedProjects: []), runHistoryStore: nil, attentionStore: .scratch(), orchestrationPersistence: persistence
        )

        await core.recoverDelegations()

        let record = try #require(try await persistence.delegation(childSessionId: "child"))
        #expect(record.phase == .failed)
        #expect(record.failureMessage == "Alas stopped before delegated session setup completed.")
    }

    /// A child a paired Mac started, caught by a restart before its session
    /// existed, restarts like a local one. What the peer allowed is not
    /// stored, so it cannot auto-run on this Mac's default, and it joins no
    /// local hierarchy.
    @Test(.timeLimit(.minutes(1))) func recoveryReattachesPeerChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("feature")
        let worktree = Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
            path: path, status: .clean, lastActivity: .distantPast
        )
        let projects = ProjectsManager(persistedProjects: [
            ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: .distantPast)
        ])
        projects.insertOptimisticWorktree(worktree)
        let agent = ACPMockClient()
        agent.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"sessionCapabilities":{}}"#.utf8) }
        agent.script(method: "session/new") { _ in Data(#"{"sessionId":"agent-1"}"#.utf8) }
        agent.script(method: "session/prompt") { _ in Data(#"{"stopReason":"end_turn"}"#.utf8) }
        let persistence = ACPOrchestrationPersistence(path: root.appendingPathComponent("orchestration.sqlite").path)
        try await persistence.insert(ACPDelegationRecord(
            childSessionId: "child", parentSessionId: ACPPeerParent.sentinel(serverId: "s1"), projectId: "p",
            parentWorktreeId: worktree.id, childWorktreeId: worktree.id, agentId: "gemini",
            worktreeRequest: .existing(worktreeId: worktree.id),
            pendingInitialPrompt: "Go", phase: .starting, failureMessage: nil, createdAt: 1, updatedAt: 1
        ))
        var configuration = AppConfig.defaults
        configuration.harness.acpAutoRunByDefault = true
        let core = AlasCoreContext(
            projects: projects, runHistoryStore: nil, attentionStore: .scratch(),
            makeSessionManager: { owner, worktree in
                ACPSessionManager(
                    worktreeId: worktree.id, worktreePath: worktree.path.path, owner: owner,
                    persistence: ACPSessionPersistence(path: root.appendingPathComponent("sessions.sqlite").path),
                    setupEvaluator: { _ in .ready },
                    connectionFactory: { _, _, _ in ACPConnection(client: agent) }
                )
            },
            environment: HeadlessHostEnvironment(configuration: configuration),
            orchestrationPersistence: persistence
        )
        defer { core.sessionManagers.values.forEach { $0.shutdownBackgroundTasks() } }

        await core.loadDelegatedSessionParents()
        await core.recoverDelegations()

        let record = try #require(try await persistence.delegation(childSessionId: "child"))
        #expect(record.phase == .ready)
        let manager = try #require(core.sessionManagers.values.first)
        #expect(manager.liveSession(for: "child")?.autoRunEnabled == false)
        try await eventually { @MainActor in agent.sent.contains { $0.params is ACPSessionPromptParams } }
        #expect(core.delegatedSessionParents["child"] == nil)
        #expect(await core.delegatedParentSessionID(for: "child") == "peer:s1")
    }
}
