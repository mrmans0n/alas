import Foundation
import Testing
@testable import Alas

struct PluginWorkspaceSnapshotTests {
    @Test func mapsWorktreesAndSessionsToTheWireShape() throws {
        func worktree(_ id: String, _ branch: String) -> Worktree {
            Worktree(id: id, projectId: "p", name: branch, branch: branch,
                     path: URL(fileURLWithPath: "/tmp/\(id)"), status: .clean, lastActivity: .distantPast)
        }
        let snapshot = PluginWorkspaceSnapshot(worktrees: [
            .init(worktree: worktree("a", "main"), dirty: .dirty(fileCount: 3, conflictCount: 1), sessions: [
                .init(id: "s1", agent: "claude", title: "Fix bug", state: .running,
                      plan: AgentSidebarPlanProgress(completed: 2, total: 5, currentStep: "Write test")),
            ]),
            .init(worktree: worktree("b", "feature"), dirty: .unknown, sessions: [
                .init(id: "s2", agent: "codex", title: "Review", state: .permissionRequest, plan: nil),
            ]),
        ], selectedWorktreeId: "a")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        #expect(json == #"{"worktrees":[{"branch":"main","current":true,"dirty":{"conflicts":1,"files":3},"id":"a","sessions":[{"agent":"claude","id":"s1","plan":{"completed":2,"total":5},"state":"running","title":"Fix bug"}]},{"branch":"feature","current":false,"id":"b","sessions":[{"agent":"codex","id":"s2","state":"permission_request","title":"Review"}]}]}"#)
    }
}
