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
}
