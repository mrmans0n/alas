import Foundation
import Testing
@testable import Alas

private func state(
    _ worktrees: [(String, Int?, Bool)] = [("w", 1, false)],
    runs: [PluginRunState] = [],
    reviews: [PluginReviewState] = []
) -> PluginEventState {
    PluginEventState(
        workspace: PluginWorkspaceSnapshot(worktrees: worktrees.map { id, files, current in
            PluginWorkspaceSnapshot.WorktreeEntry(
                id: id, branch: id, current: current,
                dirty: files.map { PluginWorkspaceSnapshot.Dirty(files: $0, conflicts: 0) }, sessions: [])
        }),
        runs: runs, reviews: reviews)
}

private func run(_ id: String, _ outcome: RunOutcome?) -> PluginRunState {
    PluginRunState(run: id, worktree: "w", script: "repo:dev.sh", outcome: outcome)
}

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
        EventCase(before: ["s1:running"], after: [], events: ["session.state:s1:gone"]),
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
        #expect(events.allSatisfy { $0.params.worktree == "w" })
        #expect(events.map { ([$0.event.rawValue, $0.params.session ?? ""] + ($0.params.state.map { [$0] } ?? [])).joined(separator: ":") } == c.events)
    }

    struct StateCase: Sendable {
        let before: PluginEventState
        let after: PluginEventState
        /// "event:worktree", plus ":run:outcome:exitCode" for runs and ":state:number:failed" for reviews.
        let events: [String]
    }

    @Test(arguments: [
        StateCase(before: state(), after: state([("w", 1, false), ("x", nil, false)]), events: ["worktree.created:x"]),
        // Created and selected between two polls.
        StateCase(before: state(), after: state([("w", 1, false), ("x", nil, true)]), events: ["worktree.created:x", "focus.changed:x"]),
        StateCase(before: state([("w", 1, false), ("x", nil, false)]), after: state(), events: ["worktree.removed:x"]),
        StateCase(before: state(), after: state([("w", 2, false)]), events: ["git.changed:w"]),
        // The first scan finishing is not a change.
        StateCase(before: state([("w", nil, false)]), after: state(), events: []),
        StateCase(before: state(), after: state([("w", 1, true)]), events: ["focus.changed:w"]),
        StateCase(before: state([("w", 1, true)]), after: state(), events: []),
        StateCase(before: state(), after: state(runs: [run("r1", nil)]), events: ["run.started:w:r1::"]),
        // Still going at the last poll, then restarted before this one: the old run ends as unknown.
        StateCase(
            before: state(runs: [run("r1", nil)]), after: state(runs: [run("r2", nil)]),
            events: ["run.finished:w:r1:unknown:", "run.started:w:r2::"]),
        StateCase(
            before: state(runs: [run("r1", nil)]), after: state(runs: [run("r1", .failed(exitCode: 2))]),
            events: ["run.finished:w:r1:failed:2"]),
        StateCase(
            before: state(runs: [run("r1", .succeeded)]), after: state(runs: [run("r2", .succeeded)]),
            events: ["run.started:w:r2::", "run.finished:w:r2:succeeded:0"]),
        StateCase(
            before: state(), after: state(reviews: [PluginReviewState(worktree: "w", state: "none")]),
            events: ["review.changed:w:none::"]),
        StateCase(
            before: state(reviews: [PluginReviewState(worktree: "w", state: "open", number: 7, checks: .init(passed: 1, failed: 0, pending: 1))]),
            after: state(reviews: [PluginReviewState(worktree: "w", state: "open", number: 7, checks: .init(passed: 1, failed: 1, pending: 0))]),
            events: ["review.changed:w:open:7:1"]),
    ])
    func eventsFollowWorktreeRunAndReviewChanges(_ c: StateCase) {
        let events = c.after.events(since: c.before).map { message -> String in
            let p = message.params
            var parts = [message.event.rawValue, p.worktree ?? ""]
            if p.run != nil { parts += [p.run ?? "", p.outcome ?? "", p.exitCode.map(String.init) ?? ""] }
            if message.event == .reviewChanged {
                parts += [p.state ?? "", p.number.map(String.init) ?? "", p.checks.map { String($0.failed) } ?? ""]
            }
            return parts.joined(separator: ":")
        }
        #expect(events == c.events)
    }
}
