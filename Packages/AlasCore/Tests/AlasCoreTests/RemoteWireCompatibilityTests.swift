import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

/// The phone decodes the Mac's wire messages with the host channel left
/// opaque, and what it re-encodes is what the Mac sent.
@Suite struct RemoteWireCompatibilityTests {
    typealias PhoneServerMessage = RemoteServerMessageOf<OpaqueHostMessage, OpaqueHostMessage>
    typealias PhoneClientMessage = RemoteClientMessageOf<OpaqueHostMessage, OpaqueHostMessage>

    /// The phone builds git actions without HostProtocol; they must read on the Mac as these requests.
    @Test(arguments: [
        (RemoteGitChange.stage(paths: ["a", "b"]), HostWorktreeChange.stage(paths: ["a", "b"])),
        (.unstage(paths: ["a"]), .unstage(paths: ["a"])),
        (.discard(paths: ["a"]), .discard(paths: ["a"])),
        (.commit(subject: "Fix", body: "Why"), .commit(subject: "Fix", body: "Why", amend: false)),
        (.push, .push(forceWithLease: false)),
        (.pull, .pull),
        (.fetch, .fetch),
        (.hunk(path: "a", index: 1, header: "@@ -1 +1 @@", linesHash: "h", action: .unstage),
         .hunk(path: "a", stage: .staged, index: 1, header: "@@ -1 +1 @@", linesHash: "h", action: .unstage)),
        (.hunk(path: "a", index: 0, header: "@@", linesHash: "h", action: .discard),
         .hunk(path: "a", stage: .unstaged, index: 0, header: "@@", linesHash: "h", action: .discard)),
    ] as [(RemoteGitChange, HostWorktreeChange)])
    func phoneGitRequestsDecodeOnTheMac(change: RemoteGitChange, expected: HostWorktreeChange) throws {
        let json = RemoteGitRequest.message(id: 7, projectID: "p", path: "/r", branch: "main", change: change).json
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: json) == HostClientMessage(
            id: 7, request: .mutateWorktree(worktree: WorktreeRef(projectID: "p", path: "/r"), branch: "main", change: expected)))
    }

    @Test(arguments: [
        (HostResponse.done, nil),
        (.failure(error: .failed(message: "Nothing is staged to commit.")), "Nothing is staged to commit."),
        (.failure(error: .operationInProgress), "Another operation is running in this worktree. Try again when it finishes."),
        (.failure(error: .session(refusal: .notWriter)), "Take over this session first."),
    ] as [(HostResponse, String?)])
    func phoneReadsTheMacsGitReply(result: HostResponse, failure: String?) throws {
        let reply = OpaqueHostMessage(json: try JSONEncoder().encode(HostServerMessage.response(id: 7, result: result)))
        #expect(RemoteGitRequest.reply(to: 8, in: reply) == nil)
        switch try #require(RemoteGitRequest.reply(to: 7, in: reply)) {
        case .success: #expect(failure == nil)
        case .failure(let error): #expect(error.message == failure)
        }
    }

    @Test func sessionDetailRoundTripsAndStaysOffTheWireWhenAbsent() throws {
        let detail = RemoteSessionDetail(model: "Opus 5.5", contextPercent: 63, planCompleted: 2, planTotal: 5,
                                         planStep: "Write tests", preview: "Done.", previewKind: .reply)
        let full = RemoteSessionSummary(id: "s", title: "T", agentId: "claude", status: "idle", canDrive: false, detail: detail)
        #expect(try JSONDecoder().decode(RemoteSessionSummary.self, from: JSONEncoder().encode(full)) == full)

        let legacy = Data(#"{"id":"s","title":"T","agentId":"claude","status":"idle","canDrive":false}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteSessionSummary.self, from: legacy)
        #expect(decoded.detail == nil)
        #expect(!String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("\"detail\""))
    }

    @Test func anUnknownPreviewKindDropsOnlyTheKind() throws {
        let json = Data(#"{"id":"s","title":"T","agentId":"claude","status":"idle","canDrive":false,"detail":{"model":"Opus","previewKind":"future","preview":"p"}}"#.utf8)
        let detail = try #require(JSONDecoder().decode(RemoteSessionSummary.self, from: json).detail)
        #expect(detail == RemoteSessionDetail(model: "Opus", preview: "p"))
    }

    @Test func phoneShepherdRequestsDecodeOnTheMac() throws {
        let list = try JSONDecoder().decode(HostClientMessage.self, from: RemoteShepherdRequest.list(id: 3).json)
        #expect(list == HostClientMessage(id: 3, request: .listSessions))
        let act = RemoteShepherdRequest.act(id: 4, sessionID: "s", action: .enableAutoMerge).json
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: act)
            == HostClientMessage(id: 4, request: .shepherdSession(sessionID: "s", action: .enableAutoMerge)))
    }

    @Test func phoneLifecycleRequestsDecodeOnTheMac() throws {
        let archive = RemoteGitRequest.archiveSession(id: 5, sessionID: "s").json
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: archive)
            == HostClientMessage(id: 5, request: .archiveSession(sessionID: "s")))
        let rename = RemoteGitRequest.renameBranch(id: 6, projectID: "p", path: "/r", from: "a", to: "b").json
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: rename) == HostClientMessage(
            id: 6, request: .renameBranch(worktree: WorktreeRef(projectID: "p", path: "/r"), from: "a", to: "b")))
        let ref = WorktreeRef(projectID: "p", path: "/r")
        let archiveWorktree = RemoteGitRequest.archiveWorktree(id: 7, projectID: "p", path: "/r", lineageID: "l", branch: "b",
                                                               discardUnsavedEdits: true).json
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: archiveWorktree) == HostClientMessage(
            id: 7, request: .archiveWorktree(worktree: ref, lineageID: "l", branch: "b", discardUnsavedEdits: true)))
        let delete = RemoteGitRequest.deleteWorktree(id: 8, projectID: "p", path: "/r", lineageID: nil, branch: "b",
                                                     force: true, deleteBranchIfMerged: true, discardUnsavedEdits: false).json
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: delete) == HostClientMessage(id: 8, request: .deleteWorktree(
            worktree: ref, lineageID: nil, branch: "b", force: true, deleteBranchIfMerged: true, discardUnsavedEdits: false)))
    }

    @Test func phoneReadsAWorktreesPullRequest() throws {
        let request = RemoteGitRequest.reviewStatus(id: 3, projectID: "p", path: "/r").json
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: request)
            == HostClientMessage(id: 3, request: .reviewStatus(worktree: WorktreeRef(projectID: "p", path: "/r"))))
        func reply(_ snapshot: ReviewLoopSnapshot?) throws -> OpaqueHostMessage {
            OpaqueHostMessage(json: try JSONEncoder().encode(HostServerMessage.response(id: 3, result: .reviewStatus(snapshot: snapshot))))
        }
        let found = try reply(ShepherdFixtures.snapshot(ShepherdFixtures.request(checks: [ShepherdFixtures.failing])))
        let pr = try #require(RemoteGitRequest.pullRequest(replying: 3, in: found) ?? nil)
        #expect(pr.number == 7 && pr.title == "Fix login" && pr.url.absoluteString == "https://github.com/acme/app/pull/7")
        #expect(pr.state == "open" && !pr.isDraft && pr.reviewDecision == "approved")
        #expect(pr.checks.map(\.name) == ["unit-tests"] && pr.checks.map(\.bucket) == ["fail"])
        #expect(pr.checks.first?.detailURL?.absoluteString == "https://ci.example/unit-tests")
        #expect(RemoteGitRequest.pullRequest(replying: 3, in: try reply(ShepherdFixtures.snapshot(nil))) == .some(nil))
        #expect(RemoteGitRequest.pullRequest(replying: 4, in: found) == nil)
    }

    /// The phone lists the Mac's open inbox items but for agent waits, which it shows as sessions.
    @Test func phoneReadsAndDismissesTheMacsInbox() throws {
        let owner = AttentionWorktreeIdentity(projectID: "p", location: .local, lineageID: "l", legacyPath: nil)
        let display = AttentionWorktreeDisplaySnapshot(projectName: "Alas", branch: "main", path: "/r", host: nil)
        func event(_ kind: AttentionKind, _ target: AttentionJumpTarget = .none) -> AttentionEvent {
            AttentionEvent(id: UUID(), sourceKey: AttentionSourceKey(rawValue: UUID().uuidString), fingerprint: "f",
                           owner: owner, kind: kind, title: "\(kind)", body: "out", jumpTarget: target, display: display,
                           occurredAt: Date(timeIntervalSinceReferenceDate: 1_000), requiresAction: true)
        }
        let failure = event(.runScriptFailure), failed = event(.agentFailed, .session(sessionID: "s1"))
        let acknowledged = event(.conflicts), waiting = event(.agentAwaiting, .session(sessionID: "s2"))
        let events = [failure, failed, acknowledged, waiting]
        var document = AttentionDocument(events: events)
        for event in events {
            document.observations[event.sourceKey] = .init(isActive: true, fingerprint: "f", eventID: event.id)
        }
        document.acknowledgments[acknowledged.id] = .init(eventID: acknowledged.id, acknowledgedAt: .now)

        let items = AttentionSignalAggregator.phoneInbox(document)
        #expect(Set(items.map(\.id)) == [failure.id, failed.id])
        #expect(items.first { $0.id == failed.id }?.sessionID == "s1")

        #expect(try JSONDecoder().decode(HostClientMessage.self, from: RemoteAttentionRequest.list(id: 4).json)
            == HostClientMessage(id: 4, request: .attention))
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: RemoteAttentionRequest.dismiss(id: 5, eventIDs: [failure.id]).json)
            == HostClientMessage(id: 5, request: .dismissAttention(eventIDs: [failure.id])))
        let reply = OpaqueHostMessage(json: try JSONEncoder().encode(HostServerMessage.response(id: 4, result: .attention(items: items))))
        #expect(RemoteAttentionRequest.items(replying: 4, in: reply) == items)
        #expect(RemoteAttentionRequest.items(replying: 9, in: reply) == nil)
    }

    @Test func phoneReadsAFilesHistory() throws {
        let request = RemoteFileHistoryRequest.request(id: 3, projectID: "p", worktreePath: "/r", path: "a.swift")
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: request.json)
            == HostClientMessage(id: 3, request: .readWorktree(worktree: WorktreeRef(projectID: "p", path: "/r"),
                                                              read: .fileHistory(path: "a.swift"))))
        let commit = CommitInfo(sha: String(repeating: "a", count: 40), shortSha: "aaaaaaa", author: "N", authorInitials: "N",
                                date: Date(timeIntervalSince1970: 1_700_000_000), subject: "s", rawSubject: "feat: s", body: "",
                                conventionalTag: "feat", filesChanged: 1, insertions: 2, deletions: 0)
        let entries = [HostFileHistoryEntry(commit: commit, pathAtCommit: "old.swift")]
        func reply(_ message: RemoteServerMessage) throws -> OpaqueHostMessage {
            OpaqueHostMessage(json: try JSONEncoder().encode(HostServerMessage.response(id: 3, result: .worktreeRead(reply: message))))
        }
        #expect(RemoteFileHistoryRequest.result(replying: 3, in: try reply(.fileHistory(sessionId: "s", path: "a.swift", entries: entries, truncated: true)))
            == .success(entries: entries, truncated: true))
        #expect(RemoteFileHistoryRequest.result(replying: 3, in: try reply(.fileHistoryFailed(sessionId: "s", path: "a.swift", reason: .notFound, message: nil)))
            == .failure(reason: .notFound, message: nil))
        #expect(RemoteFileHistoryRequest.result(replying: 4, in: try reply(.fileHistory(sessionId: "s", path: "a.swift", entries: [], truncated: false))) == nil)
    }

    @Test func aRefreshAskedForMeanwhileReplacesTheReplyInFlight() {
        var flight = RemoteSingleFlight()
        let start = ContinuousClock.now
        var steps: [Bool] = []
        steps.append(flight.shouldSend(now: start))
        // Mode B, then back to A, while the first A is out: both wait.
        steps.append(flight.shouldSend(now: start + .seconds(1)))
        steps.append(flight.shouldSend(now: start + .seconds(2)))
        // A's reply is dropped in favour of one fresh request, whose own reply shows.
        steps.append(flight.landed())
        steps.append(flight.shouldSend(now: start + .seconds(3)))
        steps.append(flight.landed())
        // A lost reply holds the next request only for a while.
        steps.append(flight.shouldSend(now: start + .seconds(4)))
        steps.append(flight.shouldSend(now: start + .seconds(4) + RemoteSingleFlight.patience))
        #expect(steps == [true, false, false, true, true, false, true, true])
    }

    @Test func phoneReadsWhatACommitMessageIsSuggestedFrom() throws {
        let request = RemoteGitRequest.commitMessageInput(id: 3, projectID: "p", path: "/r").json
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: request)
            == HostClientMessage(id: 3, request: .commitMessageInput(worktree: WorktreeRef(projectID: "p", path: "/r"))))
        let input = CommitMessageSuggestionInput(stat: " a | 1 +", diff: "diff --git a/a b/a", branch: nil,
                                                 ticketTitle: "Login", recentSubjects: ["fix: x"])
        let reply = OpaqueHostMessage(json: try JSONEncoder().encode(
            HostServerMessage.response(id: 3, result: .commitMessageInput(input: input))))
        #expect(RemoteGitRequest.commitMessageInput(in: reply) == input)
    }

    @Test func phoneRunsTheMacsScripts() throws {
        let ref = WorktreeRef(projectID: "p", path: "/r")
        let decode = { (m: OpaqueHostMessage) in try JSONDecoder().decode(HostClientMessage.self, from: m.json).request }
        #expect(try decode(RemoteGitRequest.listRunScripts(id: 1, projectID: "p", path: "/r")) == .listRunScripts(worktree: ref))
        #expect(try decode(RemoteGitRequest.run(id: 1, .start, scriptKey: "repo:a", projectID: "p", path: "/r"))
            == .startRun(scriptKey: "repo:a", worktree: ref))
        #expect(try decode(RemoteGitRequest.run(id: 1, .restart, scriptKey: "repo:a", projectID: "p", path: "/r"))
            == .restartRun(scriptKey: "repo:a", worktree: ref))
        #expect(try decode(RemoteGitRequest.run(id: 1, .stop, scriptKey: "repo:a", projectID: "p", path: "/r"))
            == .stopRun(scriptKey: "repo:a", worktree: ref))

        func reply(_ result: HostResponse) throws -> OpaqueHostMessage {
            OpaqueHostMessage(json: try JSONEncoder().encode(HostServerMessage.response(id: 2, result: result)))
        }
        let script = HostRunScript(scope: .repo, fileName: "dev.sh", name: "Dev", cwd: nil, target: RunExecutionTarget(host: nil, workingDirectory: "/r"))
        let scripts = try #require(RemoteGitRequest.runScripts(replying: 2, in: try reply(.runScripts(scripts: [script]))))
        #expect(scripts.map(\.key) == [script.key] && scripts.map(\.name) == ["Dev"])
        guard case .failure(let refused) = try #require(RemoteGitRequest.reply(
            to: 2, in: try reply(.runStart(start: .refused(title: "No", message: "Approve the hook first."))))) else {
            Issue.record("a refused launch read as started")
            return
        }
        #expect(refused.message == "Approve the hook first.")
        #expect(RemoteGitRequest.startedRunID(in: try reply(.runStart(start: .started(runID: "run-42")))) == "run-42")
    }

    @Test(arguments: [
        (RunOutcome.succeeded, Int32?.some(0)),
        (.stopped, nil),
        (.unknown, nil),
    ])
    func phoneRecoversARunsOutcomeAndResumesAfterTheSnapshot(outcome: RunOutcome, exitCode: Int32?) throws {
        let run = RunRecord(
            id: "run-42", scriptKey: "repo:build.sh", scriptName: "Build", worktreeID: "w", branch: "main",
            target: RunExecutionTarget(host: nil, workingDirectory: "/r"), status: .finished(outcome),
            startedAt: .now, sessionID: "terminal-42")
        let cursor = HostCursor(generation: UUID(), sequence: 7)
        let snapshot = HostSnapshot(cursor: cursor, projects: [], worktrees: [], workspaceCheckouts: [], runs: [run], sessions: [])
        let message = OpaqueHostMessage(json: try JSONEncoder().encode(HostServerMessage.response(
            id: 5, result: .snapshot(snapshot: snapshot))))
        guard case .snapshot(id: 5, let phoneCursor, let runs) = RemoteRunFeed.update(in: message) else {
            Issue.record("the phone missed the run snapshot")
            return
        }
        let observed = try #require(runs.first)
        #expect(observed.status == .finished(exitCode: exitCode))
        #expect(observed.visibleConsoleID == nil)
        let follow = try JSONDecoder().decode(HostClientMessage.self, from: RemoteRunFeed.subscribe(id: 6, after: phoneCursor).json)
        #expect(follow == HostClientMessage(id: 6, request: .subscribe(after: cursor)))
    }

    @Test(arguments: [false, true])
    func phoneReadsOnlyTheVisibleConsoleAndTheActualExitStatus(hidden: Bool) throws {
        let run = RunRecord(
            id: "run-42", scriptKey: "repo:build.sh", scriptName: "Build", worktreeID: "w", branch: "main",
            target: RunExecutionTarget(host: nil, workingDirectory: "/r"), status: .finished(.failed(exitCode: 17)),
            startedAt: .now, sessionID: "terminal-42", consoleIsHidden: hidden)
        let cursor = HostCursor(generation: UUID(), sequence: 7)
        let message = OpaqueHostMessage(json: try JSONEncoder().encode(HostServerMessage.events(
            events: [.runChanged(run), .runRemoved(id: "older-run")], cursor: cursor)))
        guard case .events(let changed, let removed, let resync) = RemoteRunFeed.update(in: message) else {
            Issue.record("the phone missed the run event")
            return
        }
        let observed = try #require(changed.first)
        #expect(observed.id == "run-42")
        #expect(observed.visibleConsoleID == (hidden ? nil : "terminal-42"))
        #expect(observed.status == .finished(exitCode: 17))
        #expect(removed == ["older-run"] && !resync)
    }

    @Test func previewLinkMatchesOnlyRunningLocalEndpointsInItsWorktree() throws {
        let request = RemoteRunPreview.snapshotRequest(id: 7)
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: request.json)
            == HostClientMessage(id: 7, request: .snapshot))

        let url = try #require(RemoteRunPreview.inlineURL("localhost:3000/settings?tab=account"))
        let endpoint = try #require(URL(string: "http://127.0.0.1:3000"))
        func run(_ id: String, worktree: String = "here", host: String? = nil, status: RunStatus = .running,
                 at overrideEndpoint: URL? = nil) -> RunRecord {
            RunRecord(id: id, scriptKey: "dev", scriptName: "Dev", worktreeID: worktree, branch: "main",
                      target: RunExecutionTarget(host: host, workingDirectory: "/r"),
                      endpoint: overrideEndpoint ?? endpoint, status: status, startedAt: .distantPast)
        }
        let runs = [
            run("matching"),
            run("other-worktree", worktree: "there"),
            run("ssh", host: "other-host"),
            run("stopped", status: .finished(.stopped)),
            run("other-port", at: try #require(URL(string: "http://localhost:3001"))),
            run("other-scheme", at: try #require(URL(string: "https://localhost:3000"))),
            run("other-host", at: try #require(URL(string: "http://example.com:3000"))),
        ]
        let snapshot = HostSnapshot(cursor: .init(generation: UUID(), sequence: 0), projects: [], worktrees: [],
                                    workspaceCheckouts: [], runs: runs, sessions: [])
        let message = OpaqueHostMessage(json: try JSONEncoder().encode(
            HostServerMessage.response(id: 7, result: .snapshot(snapshot: snapshot))))
        #expect(RemoteRunPreview.matchingRunIDs(replying: 7, in: message, worktreeID: "here", url: url) == ["matching"])
        #expect(RemoteRunPreview.matchingRunIDs(replying: 8, in: message, worktreeID: "here", url: url) == nil)
    }

    @Test(arguments: [
        (HostError.worktreeDeletion(refusal: .needsForce("Uncommitted changes.")), "Uncommitted changes.", RemoteGitFailure.Overrule.force),
        (.worktreeArchive(refusal: .unsavedEdits), "An editor on the machine has unsaved changes in this worktree.", .discardUnsavedEdits),
        (.worktreeDeletion(refusal: .mainWorktree), "The main checkout can't be archived or deleted.", nil),
    ] as [(HostError, String, RemoteGitFailure.Overrule?)])
    func phoneReadsTheMacsWorktreeRefusal(error: HostError, message: String, overrule: RemoteGitFailure.Overrule?) throws {
        let reply = OpaqueHostMessage(json: try JSONEncoder().encode(HostServerMessage.response(id: 7, result: .failure(error: error))))
        guard case .failure(let failure) = try #require(RemoteGitRequest.reply(to: 7, in: reply)) else {
            Issue.record("succeeded")
            return
        }
        #expect(failure == RemoteGitFailure(message, overrule: overrule))
    }

    @Test func phoneReadsASessionsShepherdFromTheMacsList() throws {
        func summary(_ id: String, _ shepherd: HostSessionShepherd?, shipsStack: Bool? = nil) -> HostSessionSummary {
            var summary = HostSessionSummary(owner: .worktree("w"), id: id, agentId: "codex", title: "t", remoteSessionId: nil,
                                             createdAt: 1, updatedAt: 2, lastOpenedAt: 3, streamingState: nil, isWriter: true)
            summary.shepherd = shepherd
            summary.shipsStack = shipsStack
            return summary
        }
        let detail = HostSessionShepherd.Detail(
            title: "Add X", url: URL(string: "https://github.com/acme/app/pull/12"), branch: "feature → main", headSHA: "a3f9c1e",
            provider: "GitHub", requestLabel: "pull request",
            checks: [.init(name: "lint", bucket: "pass", url: URL(string: "https://ci.example/lint"))],
            openThreads: 2, trustedThreads: 1, fixAttempts: 1, fixAttemptBudget: 3,
            stackEntries: [.init(position: 1, number: "#12", title: "Add X", badge: "fixing", phaseLine: "fixing")])
        let shepherd = HostSessionShepherd(badge: "fixing", number: "#12", tooltip: "#12 · fixing", resumable: false,
                                           phaseLine: "fixing", autoFix: true, autoMerge: false, detail: detail)
        let reply = OpaqueHostMessage(json: try JSONEncoder().encode(HostServerMessage.response(
            id: 5, result: .sessions(sessions: [summary("a", nil, shipsStack: true), summary("b", shepherd)]))))
        let found = try #require(RemoteShepherdRequest.listing(of: "b", replying: 5, in: reply))
        #expect(found.shepherd == RemoteShepherd(
            badge: "fixing", number: "#12", tooltip: "#12 · fixing", resumable: false, phaseLine: "fixing", autoFix: true, autoMerge: false,
            detail: RemoteShepherd.Detail(
                title: "Add X", url: URL(string: "https://github.com/acme/app/pull/12"), branch: "feature → main", headSHA: "a3f9c1e",
                provider: "GitHub", requestLabel: "pull request",
                checks: [.init(name: "lint", bucket: "pass", url: URL(string: "https://ci.example/lint"))],
                openThreads: 2, trustedThreads: 1, fixAttempts: 1, fixAttemptBudget: 3,
                stackEntries: [.init(position: 1, number: "#12", title: "Add X", badge: "fixing", phaseLine: "fixing")])))
        #expect(found.shipsStack == false)
        #expect(RemoteShepherdRequest.listing(of: "a", replying: 5, in: reply) == RemoteShepherdListing(shepherd: nil, shipsStack: true))
        #expect(RemoteShepherdRequest.listing(of: "c", replying: 5, in: reply) == nil)
        #expect(RemoteShepherdRequest.listing(of: "b", replying: 6, in: reply) == nil)

        let garbled = Data(#"{"response":{"id":9,"result":{"sessions":{"sessions":[{"id":"g","shipsStack":true,"shepherd":{"badge":"fixing","tooltip":"t","detail":{"provider":3}}}]}}}}"#.utf8)
        let kept = try #require(RemoteShepherdRequest.listing(of: "g", replying: 9, in: OpaqueHostMessage(json: garbled)))
        #expect(kept.shepherd?.badge == "fixing" && kept.shepherd?.detail == nil)
        let host = try JSONDecoder().decode(HostSessionShepherd.self, from: Data(#"{"badge":"fixing","tooltip":"t","detail":{"provider":3}}"#.utf8))
        #expect(host.badge == "fixing" && host.detail == nil)
    }

    @Test(arguments: RemoteWireSamples.serverMessages)
    func macEncodedServerMessageDecodesOnThePhone(_ message: RemoteServerMessage) throws {
        let data = try JSONEncoder.sorted.encode(message)
        let phone = try JSONDecoder().decode(PhoneServerMessage.self, from: data)
        #expect(try JSONEncoder.sorted.encode(phone) == data)
    }

    enum FoldRow: CaseIterable {
        case commentary, finalAnswer, read, subagent, emptyPlanDocument

        @MainActor var message: ACPMessage {
            switch self {
            case .commentary: .agent(id: UUID(), messageId: nil, StreamingText("thinking aloud", phase: .commentary))
            case .finalAnswer: .agent(id: UUID(), messageId: nil, StreamingText("done", phase: .finalAnswer))
            case .read: .toolCall(.init(toolCallId: "t", title: "Read a", kind: "read", status: "completed"))
            case .subagent: .toolCall(.init(
                toolCallId: "s", title: "Task", kind: "other", status: "completed",
                metadata: AnyCodable(["subagent": AnyCodable([
                    "version": AnyCodable(1), "id": AnyCodable("child"), "name": AnyCodable("Explorer"),
                    "state": AnyCodable("completed"),
                ])])))
            // The Mac shows no row for a plan document with neither text nor a file.
            case .emptyPlanDocument: .planDocument(id: UUID(), ACPPlanDocument(planId: "p", kind: .markdown, markdown: "", file: nil))
            }
        }

        var phase: String? { self == .commentary ? "commentary" : nil }
        var fold: RemoteWireMessage.Fold? {
            switch self {
            case .read: .init(joins: true, verb: "read")
            case .subagent: .init(joins: false, verb: "other")
            default: nil
            }
        }
        var isHidden: Bool? { self == .emptyPlanDocument ? true : nil }
        var subagent: RemoteWireMessage.Subagent? {
            self == .subagent ? .init(id: "child", name: "Explorer", task: nil, state: "completed", lastError: nil) : nil
        }
    }

    @MainActor // `toWire` reads a `StreamingText`.
    @Test(arguments: FoldRow.allCases)
    func toWireCarriesFoldFacts(row: FoldRow) {
        let wire = RemoteSessionGateway.toWire(row.message, index: 0, createdAt: 1_800_000_000_000)
        #expect(wire.createdAt == 1_800_000_000_000)
        #expect(wire.phase == row.phase)
        #expect(wire.fold == row.fold)
        #expect(wire.isHidden == row.isHidden)
        #expect(wire.subagent == row.subagent)
        #expect(RemoteSessionGateway.toWire(row.message, index: 0, createdAt: nil).createdAt == nil)
    }

    /// A user row carries its mentions and pasted spans, and a viewer shows
    /// the mentions in place of their `📎` lines.
    @MainActor
    @Test func userRowsCarryMentionsAndPastedSpans() throws {
        let target = ACPSymbolReference.Target(path: "Sources/A.swift", name: "run", kind: .function,
                                               container: "Runner", lineRange: 3...9, includeCode: true)
        let snapshot = ACPSymbolSnapshot(lineRange: 3...9, contentHash: "h", excerpt: "func run() {}",
                                         truncated: false, found: true)
        let spans = [ACPPastedTextSpan(ordinal: 1, utf16Offset: 18, utf16Length: 1)]
        let message = ACPMessage.user(
            id: UUID(), messageId: nil, text: "fix @Runner.run() \u{FFFC}",
            attachments: [
                .init(uri: ACPSymbolReference.uri(for: target), name: "Runner.run()", symbol: snapshot),
                .init(uri: "alas-session://abc", name: "Other chat"),
                .init(uri: "file:///repo/Sources", name: "Sources/"),
            ],
            pastedSpans: spans)
        let wire = RemoteSessionGateway.toWire(message, index: 0)
        #expect(wire.pastedSpans == spans)
        #expect(wire.mentions == [
            RemoteUserMention(kind: RemoteMention.symbol, name: "Runner.run()", symbol: RemoteSymbolMention(
                path: "Sources/A.swift", name: "run", kind: "function", container: "Runner",
                lineRange: 3...9, includesCode: true, snapshot: snapshot)),
            RemoteUserMention(kind: RemoteMention.session, name: "Other chat"),
            RemoteUserMention(kind: RemoteMention.file, name: "Sources/"),
        ])
        guard case .user(let shown, _, _, _, let mentions, let rowSpans) = RemoteTranscriptRow(message: wire) else {
            Issue.record("expected a user row")
            return
        }
        #expect(shown == "fix @Runner.run() \u{FFFC}")
        #expect(mentions == wire.mentions)
        #expect(rowSpans == spans)

        // Only the appended label goes; the user's own identical line stays.
        let own = RemoteWireMessage.userRowText(text: "📎 A.swift", attachmentNames: [], resourceNames: ["A.swift"])
        #expect(RemoteWireMessage.userRowText(own, removingResourceNames: ["A.swift"]) == "📎 A.swift")
    }

    /// Answered questions, outcome cards and failure incidents reach the phone
    /// as the values their cards draw, with their caption kept for older clients.
    @MainActor // `toWire` reads a `StreamingText`.
    @Test(arguments: StructuredRow.allCases)
    func structuredRowsDecodeOnThePhone(_ row: StructuredRow) throws {
        let wire = RemoteSessionGateway.toWire(try row.message(), index: 0)
        #expect(wire.kind == row.kind)
        #expect(wire.text == row.caption)
        let decoded = RemoteTranscriptRow(message: wire)
        switch (row, decoded) {
        case (.questionAnswer, .questionAnswer(let answer)):
            #expect(answer == StructuredRow.answer)
        case (.outcomeCard, .outcomeCard(let card)):
            #expect(ACPPromptCard(card) == StructuredRow.card)
        case (.reviewOutcomeCard, .outcomeCard(let card)):
            // The review action names a host path, so it never leaves the host.
            #expect(!(wire.json ?? "").contains("action"))
            #expect(card.actionURL == nil)
        case (.failureIncident, .failureIncident(let incident)):
            #expect(ACPFailureIncident(record: .init(remote: incident), endedTurn: incident.endedTurn)
                == (try StructuredRow.incident()).strippingActions())
        default:
            Issue.record("\(row) decoded as \(decoded)")
        }
    }

    @Test(arguments: [
        (ACPPromptCard.Action.reviewChanges(worktreeID: "wt"), true, nil as URL?),
        (.url(URL(string: "https://x/1")!), false, URL(string: "https://x/1")),
    ])
    func promptCardReadsTheActionsAPhoneCanRun(action: ACPPromptCard.Action, opensChanges: Bool, url: URL?) throws {
        let json = try JSONEncoder().encode(ACPPromptCard(origin: .review, title: "t", action: action))
        let card = try JSONDecoder().decode(RemotePromptCard.self, from: json)
        #expect(card.opensChanges == opensChanges)
        #expect(card.actionURL == url)
    }

    @Test func promptCardDecodesUnknownActionWithoutOne() throws {
        let json = #"{"origin":"fromTheFuture","title":"t","facts":[],"sections":[],"action":{"somethingNew":{}}}"#
        let card = try JSONDecoder().decode(RemotePromptCard.self, from: Data(json.utf8))
        #expect(!card.opensChanges && card.actionURL == nil)
    }

    @Test(arguments: ["questionAnswer", "outcomeCard", "failureIncident", "system"], [nil, "{"] as [String?])
    func unreadableStructuredRowsShowTheirCaption(kind: String, json: String?) {
        let wire = RemoteWireMessage(stableId: "s", kind: kind, text: "Caption", json: json, index: 0)
        #expect(RemoteTranscriptRow(message: wire) == .systemNotice("Caption"))
    }

    enum StructuredRow: String, CaseIterable, Sendable {
        case questionAnswer, outcomeCard, reviewOutcomeCard, failureIncident

        var kind: String { self == .reviewOutcomeCard ? "outcomeCard" : rawValue }

        static let answer = ACPAnsweredQuestion(
            id: UUID(), title: "Rollout", message: "Choose the rollout", outcome: .answered,
            items: [.init(question: "Strategy", description: nil, answer: "Gradual",
                          options: [.init(title: "Gradual", description: "Small batches", selected: true)])])
        static let card = ACPPromptCard(
            origin: .merged, title: "PR merged", facts: [.init(kind: .branch, text: "feature")],
            sections: [.init(title: "Checks", items: [.init(bodyMarkdown: "All green", status: .failed)])],
            action: .url(URL(string: "https://example.com/pr/1")!))

        static func incident() throws -> ACPFailureIncident {
            let json = #"{"record":{"version":1,"id":"f1","revision":1,"category":"limit","severity":"warning","title":"Slow down","details":"Rate limited","actions":["retry"]},"endedTurn":true}"#
            return try JSONDecoder().decode(ACPFailureIncident.self, from: Data(json.utf8))
        }

        func message() throws -> ACPMessage {
            switch self {
            case .questionAnswer: .questionAnswer(Self.answer)
            case .outcomeCard: .outcomeCard(ACPOutcomeCard(card: Self.card, text: "PR #1 merged"))
            case .reviewOutcomeCard:
                .outcomeCard(ACPOutcomeCard(card: ACPPromptCard(
                    origin: .queued, title: "Review queued", action: .reviewSession(.localChanges(
                        worktreeID: "w", repositoryPath: URL(fileURLWithPath: "/host/repo"), scope: .all))),
                text: "PR #1 merged"))
            case .failureIncident: .failureIncident(id: UUID(), try Self.incident())
            }
        }

        var caption: String {
            switch self {
            case .questionAnswer: Self.answer.displayText
            case .outcomeCard, .reviewOutcomeCard: "PR #1 merged"
            case .failureIncident: "Slow down\n\nRate limited"
            }
        }
    }

    @Test(arguments: RemoteWireSamples.clientMessages)
    func phoneEncodedClientMessageDecodesOnTheMac(_ message: RemoteClientMessage) throws {
        let data = try JSONEncoder.sorted.encode(message)
        let phone = try JSONDecoder().decode(PhoneClientMessage.self, from: data)
        let back = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder.sorted.encode(phone))
        #expect(back == message)
    }
}

@Suite struct PushRelayRegistrationTests {
    @Test func registrationWireShapeOmitsANilToken() throws {
        func json(_ token: String?) throws -> [String: String] {
            let data = try JSONEncoder().encode(RemoteClientMessage.pushRegistration(relayURL: "https://r.example", relayToken: token))
            return try JSONDecoder().decode([String: String].self, from: data)
        }
        #expect(try json("t") == ["type": "pushRegistration", "relayURL": "https://r.example", "relayToken": "t"])
        #expect(try json(nil) == ["type": "pushRegistration", "relayURL": "https://r.example"])
    }

    @Test(arguments: [
        ("https://r.example/push", "t", true),
        ("http://r.example/push", "t", false),
        ("not a url", "t", false),
        ("https://r.example/push", "", false),
        ("https://r.example/" + String(repeating: "a", count: 512), "t", false),
        ("https://r.example/push", String(repeating: "a", count: 1025), false),
    ])
    func relayValidationEnforcesSchemeAndCaps(url: String, token: String, valid: Bool) {
        #expect((RemotePushRelay.validated(url: url, token: token) != nil) == valid)
    }

    @Test(arguments: [
        // A phone that names no kinds gets what it got before kinds existed.
        (nil, ["permission", "input"]),
        ([], []),
        // Unknown kinds are dropped.
        (["finished", "inbox", "everything"], ["finished", "inbox"]),
    ] as [([String]?, Set<String>)])
    func relayWantsTheKindsThePhoneNamed(kinds: [String]?, wanted: Set<String>) throws {
        let relay = try #require(RemotePushRelay.validated(url: "https://r.example/push", token: "t", kinds: kinds))
        #expect(Set(["permission", "input", "finished", "inbox"].filter(relay.wants)) == wanted)
    }

    @Test func deviceWithoutPushRelayDecodesNil() throws {
        let json = #"{"id":"d","name":"n","tokenHash":"h","createdAt":0}"#
        #expect(try JSONDecoder().decode(RemoteDevice.self, from: Data(json.utf8)).pushRelay == nil)
    }

    @MainActor @Test func pushRelaySurvivesReloadAndNilClearsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("devices.json")
        FileDeviceStore(url: url).save([RemoteDevice(id: "d1", name: "Phone", tokenHash: "h", createdAt: .distantPast, lastSeenAt: nil)])
        let relay = try #require(RemotePushRelay.validated(url: "https://r.example/push", token: "t"))

        RemotePairingService(store: FileDeviceStore(url: url)).setPushRelay(relay, for: "d1")
        let reloaded = RemotePairingService(store: FileDeviceStore(url: url))
        #expect(reloaded.pushRelays.map(\.deviceID) == ["d1"])
        #expect(reloaded.pushRelays.first?.relay == relay)

        reloaded.setPushRelay(nil, for: "d1")
        #expect(RemotePairingService(store: FileDeviceStore(url: url)).pushRelays.isEmpty)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

enum RemoteWireSamples {
    static let serverMessages: [RemoteServerMessage] = [
        .sessionList(sessions: [
            RemoteSessionSummary(
                id: "s1", title: "Fix the build", agentId: "claude", status: "streaming", canDrive: true,
                tabIndex: 2, projectId: "p1", worktreeId: "w1", updatedAt: 1_800_000_000_000),
            RemoteSessionSummary(
                id: "s2", title: "Delegated", agentId: "codex", status: "idle", canDrive: true, parentSessionId: "s1"),
        ]),
        .transcriptDelta(
            sessionId: "s1", streamingState: "streaming", canDrive: true,
            upserts: [
                RemoteWireMessage(stableId: "m1", kind: "agent", text: "Running the tests/now", json: nil, index: 4),
                RemoteWireMessage(
                    stableId: "m2", kind: "toolCall", text: nil,
                    json: #"{"title":"swift test","status":"completed"}"#, index: 5, isHidden: false),
            ],
            epoch: 1, revision: 9, hasCancellableBackgroundWork: true),
        .transcriptDelta(
            sessionId: "s1", streamingState: "idle", canDrive: true,
            upserts: [
                RemoteWireMessage(
                    stableId: "m6", kind: "agent", text: "Looking around", json: nil, index: 6,
                    phase: "commentary", createdAt: 1_800_000_000_123),
                RemoteWireMessage(
                    stableId: "m7", kind: "toolCall", text: nil, json: #"{"title":"Read a"}"#, index: 7,
                    createdAt: 1_800_000_000_456, fold: .init(joins: true, verb: "read")),
            ],
            epoch: 1, revision: 10, hasCancellableBackgroundWork: false),
        .permissionRequest(sessionId: "s1", payload: RemotePermissionPayload(
            requestId: 7, toolName: "Bash",
            options: [RemotePermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")],
            title: "Run swift test?", defaultToNo: true, commandSummary: "swift test")),
        .queueState(sessionId: "s1", items: [
            RemoteQueuedPrompt(
                id: "q1", text: "Then commit", imageCount: 1, resourceCount: 0, status: "pending",
                lastError: nil, scheduledAt: 1_800_000_000_123.5, canRemove: true),
        ]),
        .host(.response(id: 3, result: .remotePairingCode(
            code: "123456", expiresAt: Date(timeIntervalSince1970: 1_800_000_000.25), link: nil))),
        .peerHost(HostClientMessage(id: 4, request: .listSessions)),
        .toolTerminal(sessionId: "s1", terminalId: "t1", text: "ok\n", truncated: true, exitCode: 1, signal: nil, retained: true),
        .toolTerminal(sessionId: "s1", terminalId: "t2", text: "", truncated: false, exitCode: nil, signal: nil, retained: false),
        .subagentTranscript(sessionId: "s1", subagentId: "c1", found: true, state: "running", messages: [
            RemoteWireMessage(
                stableId: "m3", kind: "toolCall", text: nil, json: #"{"title":"Explorer"}"#, index: 3,
                subagent: .init(id: "c2", name: "Explorer", task: "Look around", state: "failed", lastError: "boom")),
        ]),
        .subagentTranscript(sessionId: "s1", subagentId: "gone", found: false, state: nil, messages: []),
        .sessionConfig(RemoteSessionConfig(
            sessionId: "s1", models: [], modes: [], autoRunEnabled: false, acceptsImages: true,
            availableCommands: [
                RemoteSlashCommand(command: "/review", description: "Review", skill: RemoteSkillInfo(hasFile: true)),
                RemoteSlashCommand(command: "/compact"),
            ],
            codeHost: RemoteCodeHost(kind: .gitlab, host: "gitlab.example.com",
                                     webURL: URL(string: "https://gitlab.example.com/group/repo")!))),
        .transcriptDelta(
            sessionId: "s1", streamingState: "idle", canDrive: true,
            upserts: [
                RemoteWireMessage(
                    stableId: "u1", kind: "user", text: "see @run() \u{FFFC}\n\n📎 Runner.run()", json: nil, index: 8,
                    mentions: [RemoteUserMention(kind: RemoteMention.symbol, name: "Runner.run()", symbol: RemoteSymbolMention(
                        path: "Sources/A.swift", name: "run", kind: "function", container: "Runner", lineRange: 3...9,
                        includesCode: true,
                        snapshot: ACPSymbolSnapshot(lineRange: 3...9, contentHash: "h", excerpt: "func run() {}",
                                                    truncated: false, found: true)))],
                    pastedSpans: [ACPPastedTextSpan(ordinal: 1, utf16Offset: 11, utf16Length: 1)]),
            ],
            epoch: 1, revision: 11, hasCancellableBackgroundWork: false),
        .referenceSummaries(sessionId: "s1", entries: [
            RemoteReferenceEntry(spelling: "#1", summary: CodeHostReferenceSummary(
                kind: .issue, number: 1, title: "Crash", state: .closed, author: "nacho",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: nil, closedAt: nil, mergedAt: nil,
                url: URL(string: "https://gitlab.example.com/group/repo/-/issues/1")!)),
            RemoteReferenceEntry(spelling: "!2", failure: .unauthenticated(executable: "glab", host: "gitlab.example.com")),
        ]),
        .nextPromptSuggestion(sessionId: "s1", text: "Run the tests"),
        .nextPromptSuggestion(sessionId: "s1", text: nil),
    ]

    static let clientMessages: [RemoteClientMessage] = [
        .sendPrompt(
            sessionId: "s1", text: "Look at this",
            attachments: [RemoteAttachment(name: "shot.png", mimeType: "image/png", dataBase64: "iVBORw0KGgo=")],
            intent: "queue", mentions: [RemoteMention(kind: RemoteMention.file, value: "a/b.swift", name: "b.swift")]),
        .permissionDecision(sessionId: "s1", requestId: 7, optionId: "allow", persistScope: "session"),
        .pushRegistration(relayURL: "https://relay.example/push", relayToken: "tok"),
        .pushRegistration(relayURL: "https://relay.example/push", relayToken: nil),
        .pushRegistration(relayURL: "https://relay.example/push", relayToken: "tok", kinds: ["finished", "permission"]),
        .questionAnswer(sessionId: "s1", requestId: 8, answers: [
            RemoteQuestionAnswer(questionId: "q", selectedOptionIds: ["a", "b"]),
        ]),
        .queueMove(sessionId: "s1", itemId: "q1", targetItemId: "q2"),
        .setConfigOption(sessionId: "s1", configId: "thinking", value: .string("high")),
        .host(HostClientMessage(id: 5, request: .listSessions)),
        .readToolTerminal(sessionId: "s1", terminalId: "t1"),
        .readSubagent(sessionId: "s1", subagentId: "c1"),
        .sendPrompt(
            sessionId: "s1", text: "fix \u{FFFC} 👍", attachments: [], intent: "auto",
            pastedSpans: [ACPPastedTextSpan(ordinal: 1, utf16Offset: 4, utf16Length: 1)]),
        .readSkill(sessionId: "s1", command: "/review"),
        .resolveReferences(sessionId: "s1", spellings: ["#1", "!2"]),
        .suggestNextPrompt(sessionId: "s1"),
    ]
}
