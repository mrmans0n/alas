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

    struct EventCase: Sendable {
        let before: [String]
        let after: [String]
        let events: [String]
    }

    /// Sessions are written "id:state", events "event:session[:state]", all in worktree "w".
    @Test(arguments: [
        EventCase(before: ["s1:running"], after: ["s1:idle"], events: ["session.state:s1:idle", "session.finished:s1"]),
        EventCase(before: ["s1:running"], after: ["s1:running"], events: []),
        EventCase(before: [], after: ["s1:running"], events: ["session.state:s1:running"]),
        EventCase(before: ["s1:awaiting_input"], after: ["s1:idle"], events: ["session.state:s1:idle"]),
        EventCase(before: ["s1:running"], after: [], events: []),
    ])
    func sessionEventsFollowStateChanges(_ c: EventCase) {
        func snapshot(_ sessions: [String]) -> PluginWorkspaceSnapshot {
            PluginWorkspaceSnapshot(worktrees: [.init(
                id: "w", branch: "b", current: true, dirty: nil,
                sessions: sessions.map {
                    let parts = $0.split(separator: ":").map(String.init)
                    return .init(id: parts[0], agent: "claude", title: "", state: parts[1], plan: nil)
                })])
        }
        let events = snapshot(c.after).sessionEvents(since: snapshot(c.before))
        #expect(events.allSatisfy { $0.worktree == "w" })
        #expect(events.map { ([$0.event.rawValue, $0.session] + ($0.state.map { [$0] } ?? [])).joined(separator: ":") } == c.events)
    }
}
