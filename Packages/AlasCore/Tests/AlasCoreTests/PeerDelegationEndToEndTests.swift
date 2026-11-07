import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

/// Agent delegation between two real `alas-host` processes on this Mac, over a
/// real peer link on its own LAN address. Nothing of the link, pairing,
/// protocol, store or outbox is faked: the only stand-ins are the agent, a
/// scripted ACP fixture, and the agent's `alas` CLI, whose request is written
/// to the host's socket as the CLI writes it.
///
/// Serialized because each test runs two hosts with agents, which is too much
/// to multiply by the suite's size; and each host needs a stable port.
///
/// Takes over seven minutes and needs a LAN address, so it runs only when asked:
/// `ALAS_PEER_E2E=1 swift test --package-path Packages/AlasCore --filter PeerDelegationEndToEnd`
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ALAS_PEER_E2E"] == "1" && PeerLab.hasNonLoopbackAddress)
)
@MainActor
struct PeerDelegationEndToEndTests {
    // MARK: 1. Discovery and the default refusal

    @Test func anAgentSeesThePeerAndIsRefusedWhileAccessIsOff() async throws {
        try await PeerLab.run { lab in
            let parent = try await lab.startParent()
            let list = try await lab.a.cli("agent_list", session: parent)
            lab.note("agent_list: \(list.text)")
            let peers = try #require(list.json?["peers"] as? [[String: Any]], "\(list.text)")
            let peer = try #require(peers.first { $0["name"] as? String == "hostB" }, "\(list.text)")
            #expect(peer["state"] as? String == "online")
            #expect(peer["supports_delegation"] as? Bool == true)

            let offered = try await lab.a.cli("agent_list", session: parent, params: ["peer": "hostB"])
            lab.note("agent_list --peer: \(offered.text)")
            // As the design's gate says; `docs/manual-test.md` step 2 expects an
            // answer with `access: off`, which no target can give.
            #expect(!offered.ok && offered.error?.contains("Remote settings") == true, "\(offered.text)")

            let refused = try await lab.a.cli("session_new", session: parent, params: [
                "peer": "hostB", "worktree": "main", "prompt": "E2E-TOKEN=never", "agent": PeerLab.agentID,
            ])
            lab.note("refused session_new: \(refused.text)")
            #expect(!refused.ok)
            #expect(refused.error?.contains("Remote settings") == true, "\(refused.text)")
            // Nothing started there.
            #expect(try await lab.b.rows("SELECT child_session_id FROM delegations").isEmpty)
            #expect(lab.b.log(event: "prompt").isEmpty)
            // What the source recorded says the same; nobody is left waiting on it.
            let rows = try await lab.a.rows("SELECT phase, failure_message FROM delegations")
            lab.note("source rows after refusal: \(rows)")
            #expect(rows.allSatisfy { $0.hasPrefix("failed|") }, "\(rows)")
        }
    }

    // MARK: 2. A child on the target

    @Test func aChildStartsOnTheTargetUnderAskAndRunsItsTurn() async throws {
        try await PeerLab.run { lab in
            try await lab.allow("ask")
            let peersOnB = try await lab.b.tool("peers", "list")
            #expect(peersOnB.output.contains("agents: ask"), "\(peersOnB.output)")
            let parent = try await lab.startParent()

            let offered = try await lab.a.cli("agent_list", session: parent, params: ["peer": "hostB"])
            lab.note("agent_list --peer: \(offered.text)")
            let projects = (offered.json?["peer"] as? [String: Any])?["projects"] as? [[String: Any]]
            #expect(projects?.count == 1, "the shared origin should match one project: \(offered.text)")

            let child = try await lab.startChild(parent: parent, prompt: "E2E-TOKEN=first")
            try await eventually { [b = lab.b] in !b.log(event: "turn_end").isEmpty }
            #expect(lab.b.log(event: "prompt").first?["text"]?.contains("E2E-TOKEN=first") == true)

            let summary = try #require(try await lab.b.session(child), "no session \(child) on the target")
            lab.note("target summary: from=\(summary.delegatedFromName ?? "nil") parent=\(summary.parentID ?? "nil")")
            #expect(summary.delegatedFromName == "hostA")
            #expect(summary.parentID == nil, "a raw peer parent reached a client: \(summary.parentID ?? "")")
            let row = try await lab.b.rows("SELECT parent_session_id, phase FROM delegations WHERE child_session_id='\(child)'")
            lab.note("target row: \(row)")
            #expect(row.first?.hasPrefix("peer:") == true, "\(row)")

            // The child's removed tools, where its CLI calls arrive.
            let nested = try await lab.b.cli("session_new", session: child, params: ["prompt": "nested"])
            #expect(!nested.ok && nested.error?.contains("delegated from another machine") == true, "\(nested.text)")
        }
    }

    // MARK: 3. Exactly one wake

    @Test func theOutcomeReachesTheParentOnceThroughTheOutboxAndCursor() async throws {
        try await PeerLab.run { lab in
            try await lab.allow("ask")
            let parent = try await lab.startParent()
            let child = try await lab.startChild(parent: parent, prompt: "E2E-TOKEN=once")

            try await lab.waitForWake(of: "once")
            let wake = try #require(lab.a.prompts(containing: "once").first)
            lab.note("wake text: \(wake)")
            #expect(wake.contains("hostB"), "the wake should name the machine: \(wake)")
            #expect(wake.contains(child), "the wake should name the child: \(wake)")

            let cursor = try await lab.a.rows("SELECT seq FROM peer_delegation_cursors")
            lab.note("cursor on source: \(cursor)")
            #expect((cursor.first.flatMap { Int($0) } ?? 0) > 0, "\(cursor)")
            #expect(try await lab.a.rows("SELECT id FROM delegated_messages").isEmpty, "the inbox should be drained")
            let awaited = try await lab.a.rows("SELECT peer_awaiting FROM delegations WHERE child_session_id='\(child)'")
            #expect(awaited == ["0"], "\(awaited)")

            // The next outcome pulls past the cursor, which acknowledges and
            // deletes what was collected, and repeats nothing.
            _ = try await lab.a.cli("session_send", session: parent, params: ["session_id": child, "prompt": "E2E-TOKEN=again"])
            try await lab.waitForWake(of: "again")
            try await eventually { [a = lab.a] in
                ((try? await a.rows("SELECT seq FROM peer_delegation_cursors"))?.first.flatMap { Int($0) } ?? 0) > (cursor.first.flatMap { Int($0) } ?? 0)
            }
            try await lab.settle()
            #expect(lab.a.prompts(containing: "once").count == 1)
            #expect(lab.a.prompts(containing: "again").count == 1)
            let parentTurns = lab.a.log(event: "prompt").count
            lab.note("parent turns: \(parentTurns)")
            #expect(parentTurns == 2)
        }
    }

    // MARK: 4. read, wait, send, interrupt

    @Test func theParentReadsWaitsSendsAndInterrupts() async throws {
        try await PeerLab.run { lab in
            try await lab.allow("ask")
            let parent = try await lab.startParent()
            let child = try await lab.startChild(parent: parent, prompt: "E2E-TOKEN=readme")
            try await lab.waitForWake(of: "readme")

            let read = try await lab.a.cli("session_read", session: parent, params: ["session_id": child])
            lab.note("session_read: \(read.text.prefix(600))")
            #expect(read.ok && read.text.contains("fixture reply readme"), "\(read.text)")

            let settled = try await lab.a.cli("session_wait", session: parent, params: ["session_ids": [child], "timeout_ms": 5000])
            lab.note("session_wait settled: \(settled.text)")
            #expect(try lab.waited(settled, child)["settled"] as? Bool == true, "\(settled.text)")

            let sent = try await lab.a.cli("session_send", session: parent, params: ["session_id": child, "prompt": "E2E-TOKEN=second"])
            lab.note("session_send: \(sent.text)")
            #expect(sent.ok, "\(sent.text)")
            try await lab.waitForWake(of: "second")
            try await lab.settle()
            #expect(lab.a.prompts(containing: "second").count == 1)
            #expect(lab.a.prompts(containing: "readme").count == 1)

            // A running turn: not settled until it is interrupted.
            let release = lab.root.appendingPathComponent("never-released")
            let held = try await lab.a.cli("session_send", session: parent, params: ["session_id": child, "prompt": "E2E-HOLD=\(release.path)"])
            #expect(held.ok, "\(held.text)")
            try await lab.waitForHold()
            let running = try await lab.a.cli("session_wait", session: parent, params: ["session_ids": [child], "timeout_ms": 1500])
            lab.note("session_wait running: \(running.text)")
            #expect(try lab.waited(running, child)["settled"] as? Bool == false, "\(running.text)")

            let wakesBefore = lab.a.log(event: "prompt").count
            let interrupted = try await lab.a.cli("session_interrupt", session: parent, params: ["session_id": child])
            lab.note("session_interrupt: \(interrupted.text)")
            #expect(interrupted.ok, "\(interrupted.text)")
            try await eventually { [b = lab.b] in !b.log(event: "cancelled").isEmpty }
            let after = try await lab.a.cli("session_wait", session: parent, params: ["session_ids": [child], "timeout_ms": 20000])
            lab.note("session_wait after interrupt: \(after.text)")
            #expect(try lab.waited(after, child)["settled"] as? Bool == true, "\(after.text)")
            try await lab.settle()
            let phase = try await lab.a.rows("SELECT phase, peer_awaiting FROM delegations WHERE child_session_id='\(child)'")
            lab.note("after interrupt: row \(phase), new parent turns \(lab.a.log(event: "prompt").count - wakesBefore), messages: \(lab.a.log(event: "prompt").suffix(1).map { $0["text"] ?? "" })")
            #expect(phase.first?.hasSuffix("|0") == true, "nothing should still be awaited: \(phase)")
        }
    }

    // MARK: 5. New worktrees and stale code

    @Test func aNewWorktreeStartsFromThePushedBranch() async throws {
        try await PeerLab.run { lab in
            try await lab.allow("ask")
            let parent = try await lab.startParent()
            // A new commit that B's checkout has not fetched.
            let sha = try await lab.commitAndPushOnA("pushed")
            let started = try await lab.a.cli("session_new", session: parent, params: [
                "peer": "hostB", "new_worktree": ["branch": "e2e/fresh"], "prompt": "E2E-TOKEN=fresh", "agent": PeerLab.agentID,
            ])
            lab.note("session_new --new-worktree: \(started.text)")
            #expect(started.ok, "\(started.text)")
            try await lab.waitForWake(of: "fresh", within: .seconds(90))
            let worktree = lab.root.appendingPathComponent("worktrees-b")
            let found = try FileManager.default.subpathsOfDirectory(atPath: worktree.path)
                .first { $0.hasSuffix(".git") } ?? ""
            let checkout = worktree.appendingPathComponent(found).deletingLastPathComponent()
            lab.note("worktree on the target: \(checkout.path)")
            #expect(try await PeerLab.git(["rev-parse", "HEAD"], in: checkout) == sha)
            #expect(try await PeerLab.git(["rev-parse", "--abbrev-ref", "HEAD"], in: checkout) == "e2e/fresh")
        }
    }

    @Test func aNewWorktreeIsRefusedFromCodeTheTargetCannotHave() async throws {
        try await PeerLab.run { lab in
            try await lab.allow("ask")
            let parent = try await lab.startParent()
            func start(_ branch: String, base: String? = nil) async throws -> CLIAnswer {
                var worktree = ["branch": branch]
                if let base { worktree["base"] = base }
                return try await lab.a.cli("session_new", session: parent, params: [
                    "peer": "hostB", "new_worktree": worktree, "prompt": "E2E-TOKEN=\(branch)", "agent": PeerLab.agentID,
                ])
            }
            // Uncommitted changes.
            let dirty = lab.a.repo.appendingPathComponent("dirty.txt")
            try Data("x".utf8).write(to: dirty)
            let refusedDirty = try await start("dirty")
            lab.note("dirty: \(refusedDirty.text)")
            #expect(!refusedDirty.ok && refusedDirty.error?.contains("--base") == true, "\(refusedDirty.text)")
            try FileManager.default.removeItem(at: dirty)

            // An unpushed commit.
            try await PeerLab.git(["-c", "user.name=T", "-c", "user.email=t@e.st", "commit", "-q", "--allow-empty", "-m", "unpushed"], in: lab.a.repo)
            let refusedAhead = try await start("ahead")
            lab.note("unpushed: \(refusedAhead.text)")
            #expect(!refusedAhead.ok && refusedAhead.error?.contains("--base") == true, "\(refusedAhead.text)")
            #expect(try await lab.b.rows("SELECT child_session_id FROM delegations").isEmpty)

            // `--base` skips the checks.
            let based = try await start("based", base: "origin/main")
            lab.note("--base: \(based.text)")
            #expect(based.ok, "\(based.text)")
            try await lab.waitForWake(of: "based", within: .seconds(90))

            // The remote moved past what this checkout thinks it has: the target
            // fetches, sees another commit, and fails the child with a reason.
            try await PeerLab.git(["reset", "-q", "--hard", "origin/main"], in: lab.a.repo)
            try await lab.pushFromAnotherClone("elsewhere")
            let stale = try await start("stale")
            lab.note("stale: \(stale.text)")
            let staleID = try #require(stale.json?["session_id"] as? String, "\(stale.text)")
            try await eventually(within: .seconds(90)) { [a = lab.a] in
                if !a.prompts(containing: staleID).isEmpty { return true }
                let phase = try? await a.rows("SELECT phase FROM delegations WHERE child_session_id='\(staleID)'")
                return phase?.first == "failed"
            }
            let staleRow = try await lab.a.rows("SELECT phase, failure_message FROM delegations WHERE child_session_id='\(staleID)'")
            lab.note("stale on source: \(staleRow); wake: \(lab.a.prompts(containing: staleID))")
            try await lab.settle()
            #expect(lab.a.prompts(containing: staleID).count == 1, "\(lab.a.prompts(containing: staleID))")
            #expect(!lab.b.log(event: "prompt").contains { $0["text"]?.contains("E2E-TOKEN=stale") == true }, "the child ran on older code")
        }
    }

    // MARK: 6. Auto-run

    @Test func aChildAutoRunsOnlyWhenBothParentAndTargetAllowIt() async throws {
        try await PeerLab.run { lab in
            try await lab.allow("ask")
            let autoParent = try await lab.startParent(autoRun: true)

            // Parent auto-running, target on ask: the permission waits for a person.
            let asked = try await lab.startChild(parent: autoParent, prompt: "E2E-PERMISSION E2E-TOKEN=ask")
            try await eventually { [b = lab.b] in b.log(event: "permission_asked").count == 1 }
            try await lab.waitUntilBlocked(parent: autoParent, child: asked)
            #expect(lab.b.log(event: "permission_answered").isEmpty, "the child auto-ran under ask: \(lab.b.log(event: "permission_answered"))")

            // Parent auto-running, target allowing it: answered without anyone.
            try await lab.allow("auto")
            _ = try await lab.startChild(parent: autoParent, prompt: "E2E-PERMISSION E2E-TOKEN=auto")
            try await eventually { [b = lab.b] in b.log(event: "permission_asked").count == 2 }
            try await eventually(within: .seconds(20)) { [b = lab.b] in b.log(event: "permission_answered").count == 1 }
            lab.note("auto answer: \(lab.b.log(event: "permission_answered"))")
            #expect(lab.b.log(event: "permission_answered").first?["outcome"]?.contains("allow") == true)

            // Parent not auto-running, target allowing it: still waits.
            let plainParent = try await lab.startParent(autoRun: false)
            let plain = try await lab.startChild(parent: plainParent, prompt: "E2E-PERMISSION E2E-TOKEN=plain")
            try await eventually { [b = lab.b] in b.log(event: "permission_asked").count == 3 }
            try await lab.waitUntilBlocked(parent: plainParent, child: plain)
            #expect(lab.b.log(event: "permission_answered").count == 1, "\(lab.b.log(event: "permission_answered"))")
        }
    }

    // MARK: 7. Restarts

    @Test func restartingTheTargetMidTurnNeitherFailsNorDoubleWakes() async throws {
        try await PeerLab.run { lab in
            try await lab.allow("ask")
            let parent = try await lab.startParent()
            let release = lab.root.appendingPathComponent("release")
            let child = try await lab.startChild(parent: parent, prompt: "E2E-HOLD=\(release.path) E2E-TOKEN=restartb")
            try await lab.waitForHold()

            try await lab.b.stop()
            try await lab.b.start()
            try await lab.waitForOnline(parent: parent)
            try Data().write(to: release)
            lab.note("target log after restart: \(lab.b.log(event: "session_load")) \(lab.b.log(event: "exit"))")

            // Whatever became of the turn, the parent hears once and nothing is
            // failed only for the restart. Bounded by the collector's 60s retry.
            try await eventually(within: .seconds(150)) { [a = lab.a] in !a.prompts(containing: child).isEmpty }
            try await lab.settle()
            let row = try await lab.a.rows("SELECT phase, failure_message, peer_awaiting FROM delegations WHERE child_session_id='\(child)'")
            lab.note("source row: \(row)")
            lab.note("wakes: \(lab.a.prompts(containing: child))")
            #expect(row.first?.hasPrefix("failed") == false, "\(row)")
            #expect(lab.a.prompts(containing: child).count == 1, "\(lab.a.prompts(containing: child))")
        }
    }

    @Test func restartingTheSourceWithAResultWaitingWakesOnce() async throws {
        try await PeerLab.run { lab in
            try await lab.allow("ask")
            let parent = try await lab.startParent()
            let release = lab.root.appendingPathComponent("release")
            let child = try await lab.startChild(parent: parent, prompt: "E2E-HOLD=\(release.path) E2E-TOKEN=restarta")
            try await lab.waitForHold()

            try await lab.a.stop()
            try Data().write(to: release)
            try await eventually { [b = lab.b] in
                ((try? await b.rows("SELECT message_id FROM peer_outbox")) ?? []).isEmpty == false
            }
            let waiting = try await lab.b.rows("SELECT seq, child_session_id, kind FROM peer_outbox")
            lab.note("outbox on target while the source is down: \(waiting)")
            #expect(lab.a.prompts(containing: "restarta").isEmpty)

            try await lab.a.start()
            try await lab.waitForWake(of: "restarta", within: .seconds(90))
            try await lab.settle()
            lab.note("wakes: \(lab.a.prompts(containing: "restarta"))")
            #expect(lab.a.prompts(containing: "restarta").count == 1)
            let row = try await lab.a.rows("SELECT phase, peer_awaiting FROM delegations WHERE child_session_id='\(child)'")
            lab.note("source row: \(row)")
            #expect(row.first?.hasPrefix("failed") == false, "\(row)")
            let cursor = try await lab.a.rows("SELECT seq FROM peer_delegation_cursors")
            lab.note("cursor: \(cursor)")
            #expect((cursor.first.flatMap { Int($0) } ?? 0) > 0, "\(cursor)")
        }
    }

    // MARK: 8. Outage

    @Test func stoppingTheTargetIsAnOutageNotAFailure() async throws {
        try await PeerLab.run { lab in
            try await lab.allow("ask")
            let parent = try await lab.startParent()
            let release = lab.root.appendingPathComponent("release")
            let child = try await lab.startChild(parent: parent, prompt: "E2E-HOLD=\(release.path) E2E-TOKEN=outage")
            try await lab.waitForHold()

            try await lab.b.stop()
            let started = ContinuousClock.now
            var state = ""
            var answer = CLIAnswer(text: "", ok: false, error: nil, lines: [])
            while state != "peer_unreachable", ContinuousClock.now - started < .seconds(45) {
                answer = try await lab.a.cli("session_wait", session: parent, params: ["session_ids": [child], "timeout_ms": 2000])
                state = (try? lab.waited(answer, child)["state"] as? String) ?? ""
            }
            lab.note("session_wait while stopped (after \(ContinuousClock.now - started)): \(answer.text)")
            #expect(state == "peer_unreachable", "\(answer.text)")
            #expect(try lab.waited(answer, child)["settled"] as? Bool == true, "\(answer.text)")

            for (command, params) in [
                ("session_read", ["session_id": child] as [String: Any]),
                ("session_send", ["session_id": child, "prompt": "hello"]),
                ("session_interrupt", ["session_id": child]),
            ] {
                let refused = try await lab.a.cli(command, session: parent, params: params)
                lab.note("\(command) while stopped: \(refused.text)")
                #expect(!refused.ok && refused.error?.contains("hostB") == true, "\(command): \(refused.text)")
            }
            let during = try await lab.a.rows("SELECT phase FROM delegations WHERE child_session_id='\(child)'")
            #expect(during.first != "failed", "\(during)")
            #expect(lab.a.prompts(containing: child).isEmpty, "the parent was woken during the outage")

            try Data().write(to: release)
            try await lab.b.start()
            try await eventually(within: .seconds(150)) { [a = lab.a] in !a.prompts(containing: child).isEmpty }
            try await lab.settle()
            lab.note("wakes after return: \(lab.a.prompts(containing: child))")
            #expect(lab.a.prompts(containing: child).count == 1)
            let row = try await lab.a.rows("SELECT phase, failure_message FROM delegations WHERE child_session_id='\(child)'")
            lab.note("source row: \(row)")
            #expect(row.first?.hasPrefix("failed") == false, "\(row)")
        }
    }

    // MARK: 9. Revocation

    @Test func revokingOnTheTargetFailsTheAwaitedChildWithOneWake() async throws {
        try await PeerLab.run { lab in
            try await lab.allow("ask")
            let parent = try await lab.startParent()
            let release = lab.root.appendingPathComponent("never-released")
            let child = try await lab.startChild(parent: parent, prompt: "E2E-HOLD=\(release.path) E2E-TOKEN=revoked")
            try await lab.waitForHold()

            let removed = try await lab.b.tool("peers", "remove", "hostA")
            lab.note("peers remove: \(removed.status) \(removed.output) \(removed.error)")
            #expect(removed.status == 0, "\(removed.error)")

            try await eventually(within: .seconds(60)) { [a = lab.a] in !a.prompts(containing: child).isEmpty }
            try await lab.settle()
            let row = try await lab.a.rows("SELECT phase, failure_message FROM delegations WHERE child_session_id='\(child)'")
            lab.note("source row: \(row)")
            lab.note("wakes: \(lab.a.prompts(containing: child))")
            #expect(row.first?.hasPrefix("failed|") == true, "\(row)")
            #expect(lab.a.prompts(containing: child).count == 1, "\(lab.a.prompts(containing: child))")

            let list = try await lab.a.cli("agent_list", session: parent)
            lab.note("agent_list after revoke: \(list.text)")
            let waited = try await lab.a.cli("session_wait", session: parent, params: ["session_ids": [child], "timeout_ms": 3000])
            lab.note("session_wait after revoke: \(waited.text)")
            #expect(try lab.waited(waited, child)["settled"] as? Bool == true, "\(waited.text)")
        }
    }

    // MARK: 10. Access off during a turn

    @Test func turningAccessOffLetsTheTurnFinishAndRefusesNewWork() async throws {
        try await PeerLab.run { lab in
            try await lab.allow("ask")
            let parent = try await lab.startParent()
            let release = lab.root.appendingPathComponent("release")
            let child = try await lab.startChild(parent: parent, prompt: "E2E-HOLD=\(release.path) E2E-TOKEN=accessoff")
            try await lab.waitForHold()

            try await lab.allow("off")
            let duringRead = try await lab.a.cli("session_read", session: parent, params: ["session_id": child])
            #expect(duringRead.ok, "\(duringRead.text)")
            let refused = try await lab.a.cli("session_send", session: parent, params: ["session_id": child, "prompt": "more"])
            lab.note("session_send while off: \(refused.text)")
            #expect(!refused.ok && refused.error?.contains("Remote settings") == true, "\(refused.text)")

            try Data().write(to: release)
            try await lab.waitForWake(of: "accessoff")
            try await lab.settle()
            #expect(lab.a.prompts(containing: "accessoff").count == 1)
            let row = try await lab.a.rows("SELECT phase, peer_awaiting FROM delegations WHERE child_session_id='\(child)'")
            lab.note("source row: \(row)")
            #expect(row == ["ready|0"], "\(row)")

            let readAfter = try await lab.a.cli("session_read", session: parent, params: ["session_id": child])
            #expect(readAfter.ok && readAfter.text.contains("fixture reply accessoff"), "\(readAfter.text)")
            let newChild = try await lab.a.cli("session_new", session: parent, params: [
                "peer": "hostB", "worktree": "main", "prompt": "E2E-TOKEN=nope", "agent": PeerLab.agentID,
            ])
            lab.note("session_new while off: \(newChild.text)")
            #expect(!newChild.ok, "\(newChild.text)")
            #expect(!lab.b.log(event: "prompt").contains { $0["text"]?.contains("E2E-TOKEN=nope") == true })
        }
    }

    // MARK: 11. Back over the other's link

    /// B never paired with A, and cannot dial it: A paired with B, and B
    /// answered inbound-only. B's agents still reach A over A's own link,
    /// once A allows B, and the outcome comes back the same way.
    @Test func theTargetsAgentsDelegateBackOverTheSourcesLink() async throws {
        try await PeerLab.run { lab in
            let allowed = try await lab.a.tool("peers", "agents", "hostB", "ask")
            #expect(allowed.status == 0, "\(allowed.error)")
            let peersOnA = try await lab.a.tool("peers", "list")
            #expect(peersOnA.output.contains("agents: ask"), "\(peersOnA.output)")
            let parent = try await lab.startParent(on: lab.b, seeing: "hostA")

            let child = try await lab.startChild(parent: parent, prompt: "E2E-TOKEN=back", on: lab.b, at: "hostA")
            try await eventually { [a = lab.a] in a.prompts(containing: "E2E-TOKEN=back").count == 1 }
            let summary = try #require(try await lab.a.session(child), "no session \(child) on A")
            #expect(summary.delegatedFromName == "hostB")

            // The wake names the child, and it comes once.
            try await eventually(within: .seconds(60)) { [b = lab.b] in !b.prompts(containing: child).isEmpty }
            let wake = try #require(lab.b.prompts(containing: child).first)
            lab.note("wake on B: \(wake)")
            #expect(wake.contains("hostA"), "the wake should name the machine: \(wake)")
            let awaited = try await lab.b.rows("SELECT peer_awaiting FROM delegations WHERE child_session_id='\(child)'")
            #expect(awaited == ["0"], "\(awaited)")
            #expect(lab.b.prompts(containing: child).count == 1)
        }
    }
}

// MARK: - The two hosts

struct CLIAnswer: Sendable {
    let text: String
    let ok: Bool
    let error: String?
    let lines: [String]

    /// The JSON a `session_*` answer carries as its one line.
    var json: [String: Any]? {
        lines.first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}

/// One `alas-host` on its own profile and repository, which can stop and start
/// on the same data and port.
@MainActor
final class LabHost {
    let name: String
    let dataDirectory: URL
    let repo: URL
    let logFile: URL
    private(set) var process: AlasHostProcess?
    private(set) var client: SocketClient?
    private(set) var project: ProjectSnapshot?
    private var socketDirectory = ""
    private var commands: [AlasHostProcess] = []

    /// The host sets its own `GIT_SSH_COMMAND` unless one is set, and that wins
    /// over the repositories' `core.sshCommand`.
    let environment: [String: String]

    init(name: String, root: URL) {
        self.name = name
        environment = [
            "ALAS_ZMX_BINARY": "/nonexistent/zmx", "ALAS_CLI_BINARY": "/nonexistent/alas",
            "GIT_SSH_COMMAND": root.appendingPathComponent("local-ssh").path,
        ]
        dataDirectory = root.appendingPathComponent("\(name)/data")
        repo = root.appendingPathComponent("\(name)/repo")
        logFile = root.appendingPathComponent("\(name)/agent.log")
    }

    func start() async throws {
        let host = try AlasHostProcess(dataDirectory: dataDirectory, environment: environment)
        process = host
        let socket = try await host.socketPath()
        socketDirectory = (socket as NSString).deletingLastPathComponent
        client = try SocketClient(path: socket)
        try await eventually { [host] in host.output.split(separator: "\n").contains { $0.hasPrefix("remote ") } || !host.process.isRunning }
        #expect(host.process.isRunning, "\(host.errorOutput)")
        guard case .snapshot(let snapshot)? = try await client?.request(.snapshot) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(try await client?.request(.subscribe(after: snapshot.cursor)) == .subscribed)
    }

    /// Stops as a person or launchd would, and waits for the data directory to be free.
    func stop() async throws {
        client?.close()
        client = nil
        guard let host = process else { return }
        host.process.terminate()
        _ = try await host.exitStatus()
        process = nil
    }

    /// Stops whatever is left, without assuming the host still behaves.
    func shutdown() async {
        client?.close()
        client = nil
        guard let host = process else { return }
        process = nil
        host.process.terminate()
        let deadline = ContinuousClock.now + .seconds(15)
        while host.process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if host.process.isRunning { kill(host.process.processIdentifier, SIGKILL) }
    }

    func addProject() async throws {
        guard case .project(let added)? = try await client?.request(.addProject(path: repo.path, displayName: "repo", host: nil, kind: .git)) else {
            throw LabError("could not add \(repo.path) on \(name)")
        }
        project = added
    }

    /// A one-off `alas-host` command on this profile.
    func tool(_ arguments: String...) async throws -> (status: Int32, output: String, error: String) {
        let command = try AlasHostProcess(dataDirectory: dataDirectory, arguments: arguments, environment: environment)
        // Released with the lab: `AlasHostProcess` removes the profile's runtime
        // directory when it goes, which holds the running host's socket.
        commands.append(command)
        let status = try await command.exitStatus()
        return (status, command.output, command.errorOutput)
    }

    /// A request as the agent's `alas` CLI sends it, with the session's identity.
    func cli(_ command: String, session: String, params: [String: Any] = [:]) async throws -> CLIAnswer {
        let pid = try #require(process).process.processIdentifier
        let path = "\(socketDirectory)/hooks/pid-\(pid)"
        let payload = try JSONSerialization.data(withJSONObject: [
            "v": 1, "kind": "cli", "command": command, "session_id": session, "params": params,
        ] as [String: Any])
        return try await BlockingWork.run { try Self.exchange(payload, path: path) }
    }

    private nonisolated static func exchange(_ payload: Data, path: String) throws -> CLIAnswer {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var patience = timeval(tv_sec: 180, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
        guard HostSocketServer.withAddress(path, { connect(fd, $0, $1) }) == 0 else {
            throw LabError("cannot connect to \(path): \(String(cString: strerror(errno)))")
        }
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 { throw LabError("no answer from \(path): \(String(cString: strerror(errno)))") }
            if count == 0 { break }
            reply.append(contentsOf: chunk[0 ..< count])
        }
        let object = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
        return CLIAnswer(
            text: String(decoding: reply, as: UTF8.self),
            ok: object["ok"] as? Bool ?? false,
            error: object["error"] as? String,
            lines: object["lines"] as? [String] ?? []
        )
    }

    /// `query` on this profile's orchestration store, read as another process
    /// would, one row per line and columns split by `|`.
    func rows(_ query: String) async throws -> [String] {
        let database = dataDirectory.appendingPathComponent("acp-orchestration.sqlite").path
        return try await BlockingWork.run {
            let sqlite = Process()
            let output = Pipe()
            sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            sqlite.arguments = ["-readonly", database, query]
            sqlite.standardOutput = output
            sqlite.standardError = FileHandle.nullDevice
            try sqlite.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            sqlite.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
    }

    /// What this host's agents wrote to their log with `event`.
    nonisolated func log(event: String) -> [[String: String]] {
        guard let data = try? Data(contentsOf: logFile) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["event"] as? String == event else { return nil }
            return object.mapValues { value in
                (value as? String) ?? (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
            }
        }
    }

    /// The prompts this host's agents received that hold `text`.
    nonisolated func prompts(containing text: String) -> [String] {
        log(event: "prompt").compactMap(\.["text"]).filter { $0.contains(text) }
    }

    func session(_ id: String) async throws -> HostSessionSummary? {
        guard case .snapshot(let snapshot)? = try await client?.request(.snapshot) else { return nil }
        return snapshot.sessions.first { $0.id == id }
    }

    func mainWorktree() -> WorktreeRef? {
        project.map { WorktreeRef(projectID: $0.id, path: repo.standardizedFileURL.path) }
    }

    var diagnostics: String {
        guard let process else { return "\(name): stopped" }
        return "\(name) stderr:\n\(process.errorOutput)"
    }
}

struct LabError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Two hosts with a shared git remote, A paired to B with `alas-host pair` and
/// `alas-host peers add`, B holding its default access.
@MainActor
final class PeerLab {
    static let agentID = ACPRegistryInstalledAgent(
        registryID: "e2e-fixture", displayName: "Fixture", version: "1",
        command: "/usr/bin/python3", arguments: [], environment: [:], isEnabled: true
    ).agentDefinition.id

    /// `peers add` refuses to work over loopback alone.
    nonisolated static var hasNonLoopbackAddress: Bool {
        RemoteNetwork.interfaces().contains { !$0.isLoopback }
    }

    let root: URL
    let a: LabHost
    let b: LabHost
    private let origin: URL

    private init(root: URL) {
        self.root = root
        origin = root.appendingPathComponent("origin.git")
        a = LabHost(name: "a", root: root)
        b = LabHost(name: "b", root: root)
    }

    /// Runs `body` on a new lab, and removes the hosts and their files however it ends.
    static func run(_ body: (PeerLab) async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("alas-peer-e2e-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lab = PeerLab(root: root)
        do {
            try await lab.boot()
            try await body(lab)
        } catch {
            Issue.record("the scenario stopped: \(error)", sourceLocation: sourceLocation)
            lab.note(lab.a.diagnostics)
            lab.note(lab.b.diagnostics)
        }
        lab.note("source tables: \((try? await lab.a.rows("SELECT child_session_id, parent_session_id, phase, failure_message, peer_awaiting FROM delegations")) ?? [])")
        lab.note("target tables: \((try? await lab.b.rows("SELECT child_session_id, parent_session_id, phase, failure_message FROM delegations")) ?? [])")
        lab.note("source cursor: \((try? await lab.a.rows("SELECT peer_server_id, seq FROM peer_delegation_cursors")) ?? [])")
        lab.note("source inbox: \((try? await lab.a.rows("SELECT id, target_session_id, kind, claim_instance_id, claim_expires_at, substr(prompt,1,160) FROM delegated_messages")) ?? [])")
        lab.note("source parent prompts: \(lab.a.log(event: "prompt"))")
        lab.note("target fixture events: \(lab.b.log(event: "prompt").count) prompts, \(lab.b.log(event: "holding").count) holds, \(lab.b.log(event: "turn_end").count) ends, \(lab.b.log(event: "session_load").count) loads")
        lab.note("target outbox: \((try? await lab.b.rows("SELECT seq, child_session_id, message_id, kind FROM peer_outbox")) ?? [])")
        await lab.a.shutdown()
        await lab.b.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func note(_ text: String) {
        print("[peer-e2e] \(text)")
    }

    private func boot() async throws {
        try await makeRepositories()
        try writeProfile(for: a, displayName: "hostA", port: try Self.freePort(), obeys: false)
        try writeProfile(for: b, displayName: "hostB", port: try Self.freePort(), obeys: true)
        try await a.start()
        try await b.start()
        try await a.addProject()
        try await b.addProject()

        let pair = try await b.tool("pair")
        #expect(pair.status == 0, "\(pair.error)")
        let link = try #require(pair.output.split(separator: "\n").last.map(String.init), "\(pair.output)")
        let added = try await a.tool("peers", "add", link)
        #expect(added.status == 0, "\(added.error)")
        guard added.status == 0 else { throw LabError("peers add failed: \(added.error)") }
        // A host holds a token at the other limited to delegation.
        let listed = try await a.tool("peers", "list")
        #expect(listed.output.contains("this host there: delegation only"), "\(listed.output)")
    }

    /// `origin` on a host name, so the repositories' identities match as on two
    /// real Macs, but served from a bare repository here. Git stays real: the
    /// remote's `ssh` only skips the network.
    private func makeRepositories() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try await GitTemplate.repository(at: a.repo)
        try await Self.git(["clone", "-q", "--bare", a.repo.path, origin.path], in: root)
        let ssh = root.appendingPathComponent("local-ssh")
        let script = """
        #!/bin/sh
        for last; do :; done
        exec /bin/sh -c "$(printf %s "$last" | sed 's#/acme/repo.git#\(origin.path)#')"

        """
        #expect(FileManager.default.createFile(atPath: ssh.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755]))
        try await Self.git(["clone", "-q", origin.path, b.repo.path], in: root)
        for host in [a, b] {
            try await configureRemote(host.repo, ssh: ssh)
        }
    }

    private func configureRemote(_ repo: URL, ssh: URL) async throws {
        try await Self.git(["config", "core.sshCommand", ssh.path], in: repo)
        try await Self.git(["config", "ssh.variant", "simple"], in: repo)
        try await Self.git(["remote", "remove", "origin"], in: repo, allowingFailure: true)
        try await Self.git(["remote", "add", "origin", Self.originURL], in: repo)
        try await Self.git(["fetch", "-q", "origin"], in: repo)
        try await Self.git(["branch", "-q", "-u", "origin/main", "main"], in: repo)
    }

    private static let originURL = "ssh://git.test/acme/repo.git"

    private func writeProfile(for host: LabHost, displayName: String, port: UInt16, obeys: Bool) throws {
        try FileManager.default.createDirectory(at: host.dataDirectory, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/acp_fixture_agent.py")
        var environment = ["ALAS_E2E_LOG": host.logFile.path]
        if obeys { environment["ALAS_E2E_OBEY"] = "1" }
        var config = AppConfig.defaults
        config.host = HostSettings(reachability: .lan, port: port)
        config.remote.displayName = displayName
        config.worktrees.rootPath = root.appendingPathComponent("worktrees-\(host.name)").path
        config.agents.registry = [ACPRegistryInstalledAgent(
            registryID: "e2e-fixture", displayName: "Fixture", version: "1",
            command: "/usr/bin/python3", arguments: [fixture.path], environment: environment, isEnabled: true
        )]
        try PersistenceStore().write(config, to: host.dataDirectory.appendingPathComponent("app.json"))
    }

    /// B's `peers agents` for A.
    func allow(_ access: String) async throws {
        let result = try await b.tool("peers", "agents", "hostA", access)
        #expect(result.status == 0, "\(result.error)")
    }

    /// An idle root session on `source` (A unless named), once it sees
    /// `target` online, and its identity to call the CLI with.
    func startParent(autoRun: Bool = false, on source: LabHost? = nil, seeing target: String = "hostB") async throws -> String {
        let source = source ?? a
        let client = try #require(source.client)
        let ref = try #require(source.mainWorktree())
        guard case .session(let session) = try await client.request(.createSession(
            target: .worktree(ref), agentID: Self.agentID, modelID: nil, autoRun: autoRun
        )) else { throw LabError("could not start the parent") }
        let id = session.id
        try await client.waitForEvent { if case .sessionChanged(let summary) = $0 { summary.id == id && summary.isWriter } else { false } }
        try await waitForOnline(parent: id, on: source, seeing: target)
        return id
    }

    func waitForOnline(parent: String, on source: LabHost? = nil, seeing target: String = "hostB") async throws {
        let source = source ?? a
        try await eventually(within: .seconds(45)) {
            guard let list = try? await source.cli("agent_list", session: parent) else { return false }
            return (list.json?["peers"] as? [[String: Any]])?.contains {
                $0["name"] as? String == target && $0["state"] as? String == "online"
            } == true
        }
    }

    func startChild(parent: String, prompt: String, on source: LabHost? = nil, at target: String = "hostB") async throws -> String {
        let started = try await (source ?? a).cli("session_new", session: parent, params: [
            "peer": target, "worktree": "main", "prompt": prompt, "agent": Self.agentID,
        ])
        note("session_new: \(started.text)")
        return try #require(started.json?["session_id"] as? String, "\(started.text)")
    }

    /// Waits for the parent's agent to get the result carrying `token`.
    func waitForWake(of token: String, within timeout: Duration = .seconds(60), sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let a = a
        try await eventually(within: timeout, sourceLocation: sourceLocation) { !a.prompts(containing: token).isEmpty }
    }

    /// Waits for the target's agent to be inside a held turn.
    func waitForHold() async throws {
        let b = b
        let seen = b.log(event: "holding").count
        if seen > 0, b.log(event: "turn_end").count >= seen {
            try await eventually { b.log(event: "holding").count > seen }
        } else {
            try await eventually { b.log(event: "holding").count > 0 }
        }
    }

    /// Until everything the target reported has been collected and delivered.
    /// A second wake could only come from another inbox row, so a count taken
    /// after this is final.
    func settle() async throws {
        let (a, b) = (a, b)
        try await eventually {
            guard let cursor = try? await a.rows("SELECT COALESCE(MAX(seq), 0) FROM peer_delegation_cursors").first.flatMap({ Int($0) }),
                  let last = try? await b.rows("SELECT COALESCE(MAX(seq), 0) FROM peer_outbox").first.flatMap({ Int($0) }),
                  let inbox = try? await a.rows("SELECT COUNT(*) FROM delegated_messages").first.flatMap({ Int($0) })
            else { return false }
            return cursor >= last && inbox == 0
        }
    }

    /// Until the target reports `child` waiting on a person, which it never does
    /// for a request that was answered automatically.
    func waitUntilBlocked(parent: String, child: String) async throws {
        let a = a
        try await eventually {
            guard let answer = try? await a.cli(
                "session_wait", session: parent, params: ["session_ids": [child], "timeout_ms": 1000]
            ), let sessions = answer.json?["sessions"] as? [[String: Any]] else { return false }
            return sessions.first { $0["session_id"] as? String == child }?["state"] as? String == "awaiting_input"
        }
    }

    func commitAndPushOnA(_ message: String) async throws -> String {
        try await Self.git(["-c", "user.name=T", "-c", "user.email=t@e.st", "commit", "-q", "--allow-empty", "-m", message], in: a.repo)
        try await Self.git(["push", "-q", "origin", "main"], in: a.repo)
        return try await Self.git(["rev-parse", "HEAD"], in: a.repo)
    }

    func pushFromAnotherClone(_ message: String) async throws {
        let other = root.appendingPathComponent("elsewhere")
        try await Self.git(["clone", "-q", origin.path, other.path], in: root)
        try await Self.git(["-c", "user.name=T", "-c", "user.email=t@e.st", "commit", "-q", "--allow-empty", "-m", message], in: other)
        try await Self.git(["push", "-q", "origin", "HEAD:main"], in: other)
    }

    /// The entry `session_wait` answered for `child`.
    func waited(_ answer: CLIAnswer, _ child: String) throws -> [String: Any] {
        let sessions = try #require(answer.json?["sessions"] as? [[String: Any]], "\(answer.text)")
        return try #require(sessions.first { $0["session_id"] as? String == child }, "\(answer.text)")
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL, allowingFailure: Bool = false) async throws -> String {
        try await BlockingWork.run {
            let git = Process()
            let output = Pipe()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = arguments
            git.currentDirectoryURL = directory
            git.standardOutput = output
            git.standardError = FileHandle.nullDevice
            try git.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            git.waitUntilExit()
            if git.terminationStatus != 0, !allowingFailure {
                throw LabError("git \(arguments.joined(separator: " ")) failed in \(directory.path)")
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// A port nothing listens on now, for a host to bind on every interface.
    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw LabError("no free port") }
        return UInt16(bigEndian: address.sin_port)
    }
}
