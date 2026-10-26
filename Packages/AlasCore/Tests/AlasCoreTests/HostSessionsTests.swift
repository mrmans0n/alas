import Foundation
import Synchronization
import Testing
@_spi(Testing) @_spi(AppHost) @testable import AlasCore
@_spi(Testing) @_spi(AppHost) @testable import AlasHostCore

@MainActor
struct HostSessionsTests {
    /// The host's session verbs drive an agent end to end: a session is
    /// created and connected, takes a prompt, has its permission request
    /// answered once, and is stopped, renamed and archived.
    @Test func sessionVerbsDriveAnAgent() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let sessions = fixture.host.sessions

        await #expect(throws: SessionRefusal.agentUnavailable) {
            try await sessions.create(.worktree(fixture.ref), agentID: "nobody", caller: .app)
        }
        let created = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app)
        #expect(created.owner == .worktree(fixture.worktree.id))
        let id = created.id
        try await eventually { await sessions.list().first { $0.id == id }?.isWriter == true }

        try await sessions.send(id, prompt: "hello", caller: .app)
        try await eventually { fixture.agent.sent.contains { $0.method == "session/prompt" } }
        await #expect(throws: SessionRefusal.invalidSetting) {
            try await sessions.setConfigOption(id, configID: "no-such-option", value: .string("x"), caller: .app)
        }
        fixture.core.sessionManagers.values.first?.liveSession(for: id)?.availableModels = [ACPModelInfo(id: "fast", name: "Fast")]
        await #expect(throws: SessionRefusal.invalidSetting) {
            try await sessions.setModel(id, modelID: "unadvertised", caller: .app)
        }

        let requestID = JSONRPCID.number(7)
        fixture.agent.emitPermission(id: requestID, params: ACPPermissionRequestParams(
            sessionId: "agent-1",
            toolCall: ACPPermissionToolCall(
                toolCallId: "call-1", title: "Run", kind: nil, status: nil,
                content: nil, locations: nil, rawInput: nil, rawOutput: nil
            ),
            options: [
                ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once"),
                ACPPermissionOption(optionId: "reject", name: "Reject", kind: "reject_once"),
            ]
        ))
        let manager = try #require(fixture.core.sessionManagers.values.first)
        try await eventually { await manager.liveSession(for: id)?.transcript.pendingPermission != nil }
        await #expect(throws: SessionRefusal.invalidAnswer) {
            try await sessions.answerPermission(id, requestID: requestID, optionID: "maybe", caller: .app)
        }
        // Two answers race, each recording a decision for the session: only
        // the first to claim the request counts.
        let answers = [
            Task { try await sessions.answerPermission(id, requestID: requestID, optionID: "allow", scope: .session, caller: .app) },
            Task { try await sessions.answerPermission(id, requestID: requestID, optionID: "reject", scope: .session, caller: .app) },
        ]
        var refused = 0
        for answer in answers {
            do { try await answer.value } catch SessionRefusal.notPending { refused += 1 }
        }
        #expect(refused == 1)
        try await eventually { fixture.agent.permissionResponses[requestID] != nil }

        // A late reply to that request does not answer the next one, though
        // it offers the same option.
        let nextID = JSONRPCID.number(8)
        fixture.agent.emitPermission(id: nextID, params: ACPPermissionRequestParams(
            sessionId: "agent-1",
            toolCall: ACPPermissionToolCall(
                toolCallId: "call-3", title: "Delete", kind: nil, status: nil,
                content: nil, locations: nil, rawInput: nil, rawOutput: nil
            ),
            options: [ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")]
        ))
        try await eventually { await manager.permissionPolicy(for: id)?.pendingPermissionRequestID == nextID }
        await #expect(throws: SessionRefusal.notPending) {
            try await sessions.answerPermission(id, requestID: requestID, optionID: "allow", caller: .app)
        }
        try await sessions.answerPermission(id, requestID: nextID, optionID: "allow", caller: .app)

        // Another instance on the same store cannot archive what this one drives.
        let elsewhere = ACPSessionManager(
            worktreeId: fixture.worktree.id,
            worktreePath: fixture.worktree.path.path,
            owner: .worktree(fixture.worktree.id),
            persistence: ACPSessionPersistence(path: fixture.sessionsDatabase.path),
            instanceId: "elsewhere"
        )
        #expect(try await !elsewhere.archiveUnlessDrivenElsewhere(id: id))

        try await sessions.stop(id, caller: .app)
        try sessions.rename(id, title: "Renamed", caller: .app)
        #expect(sessions.list().first { $0.id == id }?.title == "Renamed")
        try await sessions.archive(id, caller: .app)
        #expect(!sessions.list().contains { $0.id == id })
        // Nobody drives an archived session again, even with a stale view of
        // it: neither a claim nor a takeover's seizure takes its lease.
        let store = ACPSessionPersistence(path: fixture.sessionsDatabase.path)
        #expect(try await store.claimLease(
            sessionId: id, instanceId: "elsewhere", pid: Int64(getpid()),
            now: Int64(Date().timeIntervalSince1970), staleAfter: 60, leaseToken: "stale"
        ) == nil)
        await #expect(throws: ACPSessionLeaseRefusal.archived) {
            try await store.seizeLease(
                sessionId: id, instanceId: "elsewhere", pid: Int64(getpid()),
                now: Int64(Date().timeIntervalSince1970), leaseToken: "seized"
            )
        }
        await #expect(throws: SessionRefusal.notFound) { try await sessions.send(id, prompt: "again", caller: .app) }
    }

    /// An answer that reaches no agent is not reported as given: a session
    /// shown here but not driven by this instance cannot pass it on.
    /// Following streams a session's transcript, for the sessions followed
    /// only, and holds the session and its change log just as long. Pending
    /// requests are covered over the wire by `aSocketClientDrivesASession`.
    @Test func followingStreamsATranscriptAndItsRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let sessions = fixture.host.sessions
        let id = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        try await eventually { await sessions.list().first { $0.id == id }?.isWriter == true }
        let manager = try #require(fixture.core.sessionManagers.values.first)
        let other = manager.createSession(agentId: "gemini")
        let log = try #require(manager.liveSession(for: id)?.transcript.changeLog)

        let subscription = fixture.host.subscribe()
        let received = Collected(subscription)
        await #expect(throws: SessionRefusal.notFound) { try subscription.follow("no-such-session") }
        try subscription.follow(id)
        #expect(log.isTracking)
        try await eventually { await received.deltas(of: id).first?.reset == true }

        try await sessions.send(id, prompt: "hello", caller: .app)
        try await eventually {
            await received.deltas(of: id).contains { !$0.reset && $0.messages.contains { $0.kind == "user" && $0.payload.contains("hello") } }
        }

        // Only followed sessions stream.
        other.transcript.messages.append(.systemNotice(id: UUID(), text: "unfollowed"))
        manager.liveSession(for: id)?.transcript.messages.append(.systemNotice(id: UUID(), text: "followed"))
        try await eventually {
            await received.deltas(of: id).contains { $0.messages.contains { $0.payload.contains("followed") } }
        }
        #expect(received.deltas(of: other.id).isEmpty)

        // A tool call that holds only the start of its output says so: the
        // store's encoding cannot.
        var call = ACPMessage.ToolCall(
            toolCallId: "t", title: "read", status: "completed", content: String(repeating: "x", count: 50_000), preview: "x")
        call.truncateForOffWindow()
        manager.liveSession(for: id)?.transcript.messages.append(.toolCall(call))
        try await eventually {
            await received.deltas(of: id).contains { $0.messages.contains { $0.kind == "tool_call" && $0.truncated == true } }
        }

        // A second follower resumes from where the first got to.
        let resumed = fixture.host.subscribe()
        let resumedEvents = Collected(resumed)
        try resumed.follow(id, from: try #require(received.deltas(of: id).last).revision)
        manager.liveSession(for: id)?.transcript.messages.append(.systemNotice(id: UUID(), text: "more"))
        try await eventually { await resumedEvents.deltas(of: id).first.map { !$0.reset } == true }

        subscription.unfollow(id)
        #expect(log.isTracking)
        resumed.cancel()
        #expect(!log.isTracking)

        // Changes while nobody follows are not logged, so resuming from
        // before them starts over.
        let lastSeen = try #require(resumedEvents.deltas(of: id).last).revision
        manager.liveSession(for: id)?.transcript.messages.append(.systemNotice(id: UUID(), text: "unseen"))
        let late = fixture.host.subscribe()
        let lateEvents = Collected(late)
        try late.follow(id, from: lastSeen)
        try await eventually { await lateEvents.deltas(of: id).first?.reset == true }
        late.cancel()

        // A follower keeps an idle session loaded after its last tab closes.
        manager.retainSession(id: other.id)
        let idle = fixture.host.subscribe()
        try idle.follow(other.id)
        manager.releaseSession(id: other.id)
        #expect(manager.liveSession(for: other.id) != nil)
        idle.unfollow(other.id)
        #expect(manager.liveSession(for: other.id) == nil)
        // An evicted session can be loaded again.
        await manager.flushAllPersistence()
        try await sessions.load(other.id)
        #expect(manager.liveSession(for: other.id) != nil)

        // Older messages come a page at a time.
        let count = try #require(manager.liveSession(for: id)).transcript.messages.count
        let page = try sessions.transcriptPage(id, before: count, limit: 2)
        #expect(page.messages.map(\.index) == [count - 2, count - 1])
        #expect(page.messageCount == count)
    }

    /// A delegated child is admitted as any new session is: while a
    /// checkpoint restore is being recovered, it is refused.
    @Test func aChildIsRefusedWhereANewSessionWouldBe() async throws {
        let environment = RefusingEnvironment()
        let fixture = try Fixture(environment: environment)
        defer { fixture.tearDown() }
        let parent = try await fixture.host.sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app)
        let origin = try #require(fixture.core.acpSessionLocation(parent.id)?.origin)
        environment.recovering = true

        _ = await fixture.core.orchestration.create(origin: origin, request: .init(prompt: "Go", agentId: "gemini", worktree: .current))

        let persistence = fixture.core.orchestrationPersistence
        try await eventually { (try? await persistence.children(parentSessionId: parent.id))?.first?.phase == .failed }
        let child = try #require(try await persistence.children(parentSessionId: parent.id).first)
        #expect(child.failureMessage?.contains(SessionsAPI.checkpointRecoveryReason) == true)
    }

    /// A child waiting to start is admitted for its worktree as listed now:
    /// one that moved to a remote project is refused an agent that runs
    /// only locally, though the child was asked for under a local one.
    @Test func aChildIsAdmittedForItsWorktreesCurrentProject() async throws {
        let environment = RefusingEnvironment()
        environment.localOnlyAgents = true
        let fixture = try Fixture(environment: environment, projectHost: "build")
        defer { fixture.tearDown() }
        let listed = fixture.worktree
        let stale = Worktree(
            id: listed.id, projectId: "local", name: listed.name, branch: listed.branch,
            path: listed.path, status: listed.status, lastActivity: listed.lastActivity
        )

        #expect(await fixture.host.sessions.refusal(toStart: "gemini", in: stale) == .agentUnavailable)
    }

    enum ChildWorktreeChange: CaseIterable {
        /// Removed before the child reached admission.
        case removed
        /// Moved to a remote project while admission waited on the
        /// recovery check.
        case movedDuringAdmission
    }

    /// A child is refused where its worktree is no longer its project's,
    /// and no manager is created for a worktree that is gone.
    @Test(arguments: ChildWorktreeChange.allCases)
    func aChildIsRefusedWhenItsWorktreeLeavesItsProject(_ change: ChildWorktreeChange) async throws {
        let environment = RefusingEnvironment()
        environment.localOnlyAgents = true
        var remote = ProjectConfig(id: "q", name: "q", path: "/tmp/q", color: "blue", addedAt: .distantPast)
        remote.host = "build"
        let fixture = try Fixture(environment: environment, otherProjects: [remote])
        defer { fixture.tearDown() }
        let worktree = fixture.worktree
        let projects = fixture.core.projects
        switch change {
        case .removed:
            projects.dropRemovedWorktree(id: worktree.id, projectId: "p")
        case .movedDuringAdmission:
            var moved = false
            environment.duringRecoveryCheck = {
                guard !moved else { return }
                moved = true
                projects.dropRemovedWorktree(id: worktree.id, projectId: "p")
                projects.insertOptimisticWorktree(Worktree(
                    id: worktree.id, projectId: "q", name: worktree.name, branch: worktree.branch,
                    path: worktree.path, status: worktree.status, lastActivity: worktree.lastActivity
                ))
            }
        }

        #expect(await fixture.host.sessions.refusal(toStart: "gemini", in: worktree)
            == .ownerUnavailable(reason: "The worktree is not listed, or is archived."))
        if change == .removed { #expect(fixture.core.sessionManagers.isEmpty) }
    }

    /// A session id can repeat across owners: a read scoped to one owner
    /// gets that owner's session only.
    @Test func ownerScopedReadsReachOnlyThatOwnersSession() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let path = fixture.root.appendingPathComponent("other")
        let other = Worktree(
            id: Worktree.makeId(path: path), projectId: "p", name: "other", branch: "other",
            path: path, status: .clean, lastActivity: .distantPast
        )
        fixture.core.projects.insertOptimisticWorktree(other)
        for (worktree, reply) in [(fixture.worktree, "mine"), (other, "theirs")] {
            let session = try fixture.core.sessionManager(for: worktree).createSession(id: "same", agentId: "gemini", autoRunDefault: false)
            session.transcript.messages = [.agent(id: UUID(), messageId: nil, StreamingText(reply))]
        }

        #expect(fixture.host.sessions.lastAgentReply("same", owner: .worktree(fixture.worktree.id)) == "mine")
        #expect(fixture.host.sessions.lastAgentReply("same", owner: .worktree(other.id)) == "theirs")
    }

    /// A delegated session's summary names the session that delegated it.
    @Test func aDelegatedSessionsSummaryNamesItsParent() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let manager = try fixture.core.sessionManager(for: fixture.worktree)
        let parent = manager.createSession(agentId: "gemini")
        let child = manager.createSession(agentId: "gemini")

        fixture.core.rememberDelegatedSessionParent(childID: child.id, parentID: parent.id)

        let summaries = fixture.host.sessions.list()
        #expect(summaries.first { $0.id == child.id }?.parentID == parent.id)
        #expect(summaries.first { $0.id == parent.id }?.parentID == nil)
    }

    /// A listed session whose stored transcript cannot be read back, here
    /// because another instance deleted it, is not loaded.
    @Test func aSessionThatCannotBeReadBackIsNotLoaded() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let manager = try fixture.core.sessionManager(for: fixture.worktree)
        let session = manager.createSession(agentId: "gemini")
        await manager.flushAllPersistence()
        manager.retainSession(id: session.id)
        manager.releaseSession(id: session.id)
        #expect(manager.liveSession(for: session.id) == nil)
        try await manager.persistence.deleteSession(id: session.id)

        await #expect(throws: SessionRefusal.notFound) { try await fixture.host.sessions.load(session.id) }
    }

    /// A follower hears what the session is set to besides its transcript,
    /// and again when that changes.
    @Test func followingStreamsTheSessionState() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let sessions = fixture.host.sessions
        let id = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        try await eventually { await sessions.list().first { $0.id == id }?.isWriter == true }
        let subscription = fixture.host.subscribe()
        let received = Collected(subscription)
        try subscription.follow(id)
        try await eventually { await received.states(of: id).last?.isWriter == true }
        #expect(received.states(of: id).last?.config.autoRunEnabled == false)

        try await sessions.setAutoRun(id, enabled: true, caller: .app)
        try await eventually { await received.states(of: id).last?.config.autoRunEnabled == true }
        subscription.cancel()
    }

    /// A follower hears why the agent cannot run, and that it is fixed once
    /// a takeover finds the agent set up.
    @Test func followingCarriesWhyTheAgentCannotRun() async throws {
        let setup = Mutex(ACPSetupResult.missing(reason: "gemini is not installed"))
        let fixture = try Fixture(setupEvaluator: { _ in setup.withLock { $0 } })
        defer { fixture.tearDown() }
        let sessions = fixture.host.sessions
        let id = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        let subscription = fixture.host.subscribe()
        defer { subscription.cancel() }
        let received = Collected(subscription)
        try subscription.follow(id)
        try await eventually { await received.states(of: id).last?.config.agentIssue != nil }
        #expect(received.states(of: id).last?.config.agentIssue
            == RemoteAgentIssue(kind: "needsSetup", message: "gemini is not installed"))

        setup.withLock { $0 = .ready }
        try await sessions.takeOver(id, caller: .app)
        try await eventually { await received.states(of: id).last?.config.agentIssue == nil }
    }

    /// A Remote client whose prompt fails hears why with the rejection, as
    /// the sessionConfig saying so may come later or not at all.
    @Test func aRejectedRemotePromptCarriesItsReason() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let sessions = fixture.host.sessions
        let id = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        let manager = try #require(fixture.core.sessionManagers.values.first)
        try await eventually { await manager.liveSession(for: id)?.agentState == .ready }
        fixture.agent.script(method: "session/prompt") { _ in throw JSONRPCError(code: -32603, message: "boom", data: nil) }
        let sent = Mutex<[RemoteServerMessage]>([])
        let gateway = RemoteSessionGateway(host: fixture.host) { message in sent.withLock { $0.append(message) } }
        defer { gateway.close() }

        await gateway.handle(.sendPrompt(sessionId: id, text: "hi", attachments: [], intent: "auto"))
        try await eventually {
            sent.withLock {
                $0.contains { if case .promptRejected(id, let reason) = $0 { reason?.hasPrefix("prompt failed:") == true } else { false } }
            }
        }
    }

    @Test(arguments: [
        (ACPSession.AgentState.ready, ACPSession.SetupState.ready, nil, nil),
        (.spawning, .checking, nil, nil),
        (.disconnected, .ready, nil, nil),
        (.failed("spawn failed"), .ready, nil, RemoteAgentIssue(kind: "failed", message: "spawn failed")),
        (.failed("spawn failed"), .ready, "Broken pipe", RemoteAgentIssue(kind: "failed", message: "Broken pipe")),
        (.ready, .ready, "Prompt failed: rate limited", RemoteAgentIssue(kind: "error", message: "Prompt failed: rate limited")),
        (.failed("x"), .needsAuth(methods: [.init(id: "login", name: "Login", kind: .terminal)], reason: "Token expired."), nil,
         RemoteAgentIssue(kind: "needsAuth", message: "Codex needs sign-in before it can continue. Token expired.")),
        (.failed("x"), .needsSetup(reason: "missing"), nil,
         RemoteAgentIssue(kind: "needsSetup", message: "Codex requires the ACP adapter to be installed.")),
        (.failed("x"), .setupError(reason: "Probe timed out"), nil,
         RemoteAgentIssue(kind: "setupError", message: "Probe timed out")),
    ] as [(ACPSession.AgentState, ACPSession.SetupState, String?, RemoteAgentIssue?)])
    func agentIssueWordsItAsTheHostBannerDoes(
        agentState: ACPSession.AgentState, setupState: ACPSession.SetupState, lastError: String?, issue: RemoteAgentIssue?
    ) {
        #expect(RemoteSessionConfigProjection.agentIssue(
            agentName: "Codex", managedAdapter: true,
            agentState: agentState, setupState: setupState, lastError: lastError) == issue)
    }

    /// A host socket client creates a session against a scripted agent,
    /// follows it, prompts it, watches the transcript stream, answers its
    /// permission request mid-turn and stops it.
    @Test func aSocketClientDrivesASession() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // The turn lasts until the agent is told to stop.
        let (cancelled, cancel) = AsyncStream<Void>.makeStream()
        fixture.agent.scriptNotifyAsync(method: "session/cancel") { _ in cancel.yield() }
        fixture.agent.scriptAsync(method: "session/prompt") { _ in
            for await _ in cancelled { break }
            return Data(#"{"stopReason":"cancelled"}"#.utf8)
        }
        // Short: a socket path must fit in `sun_path`.
        let socketDirectory = URL(fileURLWithPath: "/tmp/alas-host-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
        let path = socketDirectory.appendingPathComponent("host.sock").path
        let socket = try #require(HostSocketServer(path: path, server: HostProtocolServer(host: fixture.host)))
        defer { socket.stop() }
        let client = try SocketClient(path: path)
        defer { client.close() }

        guard case .snapshot(let snapshot) = try await client.request(.snapshot) else {
            Issue.record("expected a snapshot")
            return
        }
        for request in [HostRequest.followSession(sessionID: "s", from: nil), .unfollowSession(sessionID: "s")] {
            #expect(try await client.request(request) == .failure(error: .invalidRequest(reason: "Subscribe before following a session.")))
        }
        #expect(try await client.request(.subscribe(after: snapshot.cursor)) == .subscribed)
        guard case .session(let created) = try await client.request(.createSession(
            target: .worktree(fixture.ref), agentID: "gemini", modelID: nil, autoRun: false
        )) else {
            Issue.record("expected the created session")
            return
        }
        let id = created.id
        try await client.waitForEvent { if case .sessionChanged(let summary) = $0 { summary.id == id && summary.isWriter } else { false } }

        #expect(try await client.request(.followSession(sessionID: id, from: nil)) == .done)
        try await client.waitForEvent { if case .transcript(_, id, let delta) = $0 { delta.reset } else { false } }
        // A prompt is answered when its turn ends; requests meanwhile are independent.
        async let prompted = client.request(.sendPrompt(sessionID: id, prompt: "hello"))
        try await client.waitForEvent { event in
            guard case .transcript(_, id, let delta) = event else { return false }
            return delta.messages.contains { $0.kind == "user" && $0.payload.contains("hello") }
        }

        let requestID = JSONRPCID.number(7)
        fixture.agent.emitPermission(id: requestID, params: ACPPermissionRequestParams(
            sessionId: "agent-1",
            toolCall: ACPPermissionToolCall(
                toolCallId: "call-1", title: "Run", kind: nil, status: nil,
                content: nil, locations: nil, rawInput: nil, rawOutput: nil
            ),
            options: [ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")]
        ))
        try await client.waitForEvent { if case .pendingRequest(_, id, .permission(requestID, _)) = $0 { true } else { false } }
        #expect(try await client.request(.answerPermission(sessionID: id, requestID: requestID, optionID: "allow", scope: .once)) == .done)
        try await client.waitForEvent { $0 == .pendingRequestResolved(owner: created.owner, id: id, requestID: .permission(requestID)) }
        #expect(fixture.agent.permissionResponses[requestID]?.outcome == .selected(optionId: "allow"))

        #expect(try await client.request(.stopSession(sessionID: id)) == .done)
        try await client.waitForEvent { if case .transcript(_, id, let delta) = $0 { delta.streamingState == .idle } else { false } }
        #expect(fixture.agent.sent.contains { $0.method == "session/cancel" })
        #expect(try await prompted == .done)
        // Session state is for in-process followers: a client of a released
        // host protocol cannot decode it.
        #expect(await !client.events.contains { if case .sessionState = $0 { true } else { false } })
    }

    /// A socket client learns what the host serves, and receives session
    /// state only once it accepts it.
    @Test func aSocketClientOptsIntoSessionState() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let socketDirectory = URL(fileURLWithPath: "/tmp/alas-host-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
        let path = socketDirectory.appendingPathComponent("host.sock").path
        let socket = try #require(HostSocketServer(path: path, server: HostProtocolServer(host: fixture.host)))
        defer { socket.stop() }
        let client = try SocketClient(path: path)
        defer { client.close() }

        #expect(try await client.request(.capabilities) == .capabilities(capabilities: HostProtocolCapability.served + HostProtocolCapability.headlessOnly))
        guard case .snapshot(let snapshot) = try await client.request(.snapshot) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(try await client.request(.subscribeAccepting(after: snapshot.cursor, events: ["sessionState"])) == .subscribed)
        guard case .session(let created) = try await client.request(.createSession(
            target: .worktree(fixture.ref), agentID: "gemini", modelID: nil, autoRun: false
        )) else {
            Issue.record("expected the created session")
            return
        }
        #expect(try await client.request(.followSession(sessionID: created.id, from: nil)) == .done)
        try await client.waitForEvent { if case .sessionState(_, created.id, _) = $0 { true } else { false } }
    }

    @Test func answersWithNoAgentToReceiveThemAreRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let manager = try fixture.core.sessionManager(for: fixture.worktree)
        let session = manager.createSession(agentId: "gemini")
        session.transcript.pendingQuestion = .init(id: .number(3), params: ACPQuestionRequestParams(
            toolCallId: "call-1", title: nil,
            questions: [ACPQuestion(id: "q", prompt: "Which?", options: [ACPQuestionOption(id: "a", label: "A")], allowMultiple: false)]
        ))

        await #expect(throws: SessionRefusal.notWriter) {
            try await fixture.host.sessions.answerQuestion(
                session.id, requestID: .number(3), answers: [ACPQuestionAnswer(questionId: "q", selectedOptionIds: ["a"])], caller: .app
            )
        }
    }

    /// A headless host ends a Workspace checkout's sessions before the
    /// checkout is archived or removed, as the app does.
    @Test func headlessCheckoutTeardownEndsItsSessions() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let id = try await fixture.addCheckout(operation: .idle, location: .local)
        let created = try await fixture.host.sessions.create(.workspaceCheckout(id: id), agentID: "gemini", caller: .app)
        #expect(fixture.core.sessionManagers[created.owner] != nil)

        let checkout = try await WorkspaceAutomationService(store: fixture.core.workspaceStore).checkout(id: id)
        try await fixture.core.environment.stopWorkspaceCheckoutSessions(checkout, in: fixture.core)
        #expect(fixture.core.sessionManagers[created.owner] == nil)
    }

    /// After another instance takes the session over, whatever this one still
    /// holds is refused: a setting the session drops, and an answer that would
    /// resume the agent beside the new writer.
    @Test func settingsLostToATakeoverAreRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let sessions = fixture.host.sessions
        let id = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        try await eventually { await sessions.list().first { $0.id == id }?.isWriter == true }
        let manager = try #require(fixture.core.sessionManagers.values.first)
        fixture.agent.emitPermission(id: .number(9), params: ACPPermissionRequestParams(
            sessionId: "agent-1",
            toolCall: ACPPermissionToolCall(
                toolCallId: "call-2", title: "Write", kind: nil, status: nil,
                content: nil, locations: nil, rawInput: nil, rawOutput: nil
            ),
            options: [ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")]
        ))
        try await eventually { await manager.permissionPolicy(for: id)?.pendingPermissionRequestID == .number(9) }

        // Another instance takes the lease while this one still believes it holds it.
        let store = ACPSessionPersistence(path: fixture.sessionsDatabase.path)
        try await store.releaseLease(sessionId: id, instanceId: manager.instanceId)
        _ = try await store.claimLease(
            sessionId: id, instanceId: "elsewhere", pid: Int64(getpid()),
            now: Int64(Date().timeIntervalSince1970), staleAfter: 60, leaseToken: "theirs"
        )
        #expect(manager.isWriter(for: id), "the takeover is not observed yet")

        await #expect(throws: SessionRefusal.notWriter) {
            try await sessions.answerPermission(id, requestID: .number(9), optionID: "allow", caller: .app)
        }
        // Standing down cancels the request; the answer never reaches the agent.
        #expect(fixture.agent.permissionResponses[.number(9)]?.outcome != .selected(optionId: "allow"))
        await #expect(throws: SessionRefusal.notWriter) {
            try await sessions.setModel(id, modelID: "fast", caller: .app)
        }
    }

    /// A client with a stale view may ask to take over a session this
    /// instance already drives; the agent keeps running and takes the prompt.
    @Test func aTakeoverByTheWriterKeepsItsAgent() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let sessions = fixture.host.sessions
        let id = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        let manager = try #require(fixture.core.sessionManagers.values.first)
        try await eventually { await manager.liveSession(for: id)?.agentState == .ready }

        try await sessions.takeOver(id, caller: .app)
        #expect(manager.liveSession(for: id)?.agentState == .ready)
        try await sessions.send(id, prompt: "hello", caller: .app)
        #expect(fixture.agent.sent.filter { $0.method == "initialize" }.count == 1)
    }

    /// An attachment of this instance can hold the session's lease before
    /// the manager records it; archiving fences with that lease and leaves it.
    @Test func archiveUsesALeaseThisInstanceAlreadyHolds() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let manager = try fixture.core.sessionManager(for: fixture.worktree)
        let session = manager.createSession(agentId: "gemini")
        await manager.flushAllPersistence()
        let store = ACPSessionPersistence(path: fixture.sessionsDatabase.path)
        _ = try await store.claimLease(
            sessionId: session.id, instanceId: manager.instanceId, pid: Int64(getpid()),
            now: Int64(Date().timeIntervalSince1970), staleAfter: 60, leaseToken: "attaching"
        )

        try await fixture.host.sessions.archive(session.id, caller: .app)
        #expect(!fixture.host.sessions.list().contains { $0.id == session.id })
        #expect(try await store.loadLease(sessionId: session.id)?.token == "attaching")
    }

    /// Archiving right after creating waits for the session's row, and no
    /// later snapshot of the session brings it back.
    @Test func archivingJustAfterCreatingSticks() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let id = try await fixture.host.sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        try await fixture.host.sessions.archive(id, caller: .app)

        let manager = try #require(fixture.core.sessionManagers.values.first)
        await manager.flushAllPersistence()
        #expect(try await ACPSessionPersistence(path: fixture.sessionsDatabase.path).loadSession(id: id)?.archived == true)
        #expect(!fixture.host.sessions.list().contains { $0.id == id })
    }

    /// A recovery that rotates the lease of a session archived meanwhile
    /// gets no lease, rather than one the store never took.
    @Test func recoveryCannotRotateTheLeaseOfAnArchivedSession() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let manager = try fixture.core.sessionManager(for: fixture.worktree)
        let session = manager.createSession(agentId: "gemini")
        await manager.flushAllPersistence()
        let store = ACPSessionPersistence(path: fixture.sessionsDatabase.path)
        let now = Int64(Date().timeIntervalSince1970)
        _ = try await store.claimLease(
            sessionId: session.id, instanceId: "recovering", pid: Int64(getpid()), now: now, staleAfter: 60, leaseToken: "old"
        )
        try await store.setArchived(id: session.id, archived: true)

        let rotated = try await store.rotateRemoteRecoveryLease(
            fence: ACPSessionLeaseFence(sessionId: session.id, ownerInstance: "recovering", token: "old"),
            pid: Int64(getpid()), now: now, token: "new"
        )
        #expect(rotated == nil)
    }

    /// A session another instance archived leaves this one's list on its
    /// next read of the store, even while it is still loaded here.
    /// Another instance archives the session, or deletes it outright.
    @Test(arguments: [false, true])
    func sessionsArchivedElsewhereLeaveTheList(deleted: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let manager = try fixture.core.sessionManager(for: fixture.worktree)
        let session = manager.createSession(agentId: "gemini")
        await manager.flushAllPersistence()
        try await eventually { await fixture.host.sessions.list().contains { $0.id == session.id } }

        let elsewhere = ACPSessionPersistence(path: fixture.sessionsDatabase.path)
        if deleted {
            try await elsewhere.deleteSession(id: session.id)
        } else {
            try await elsewhere.setArchived(id: session.id, archived: true)
        }
        await manager.refreshRecentNow()
        #expect(!fixture.host.sessions.list().contains { $0.id == session.id })
        // Nor does renaming it bring it back.
        #expect(!manager.renameSessionCosmetic(id: session.id, title: "Renamed", source: .local))
        #expect(!fixture.host.sessions.list().contains { $0.id == session.id })
    }

    enum Unavailable: CaseIterable {
        /// An interrupted checkpoint restore is being recovered.
        case recoveringCheckpoint
        /// Something is changing the Workspace checkout.
        case busyCheckout
        /// The agent cannot run on the checkout's SSH host.
        case agentNotOnRemoteHost
        /// An archive or delete claims the worktree while creation waits.
        case worktreeClaimedMeanwhile
        /// The worktree belongs to a remote project, which a headless host
        /// cannot run agents for.
        case remoteWorktree
        /// A checkpoint recovery starts while a checkout session is created.
        case recoveryStartsMeanwhile
        /// The host's own view says the owner is being changed as creation ends.
        case ownerClaimedAsCreationEnds
        /// The agent is disabled while creation waits.
        case agentDisabledMeanwhile
        /// No such Workspace checkout, or an archived one.
        case missingCheckout
    }

    /// A session is not created where it could not safely run.
    @Test(arguments: Unavailable.allCases)
    func creationIsRefusedWhereASessionCannotRun(_ reason: Unavailable) async throws {
        let environment = RefusingEnvironment()
        let fixture = try Fixture(environment: environment, projectHost: reason == .remoteWorktree ? "build" : nil)
        defer { fixture.tearDown() }
        let target: SessionTarget
        let refusal: SessionRefusal
        switch reason {
        case .recoveringCheckpoint:
            environment.recovering = true
            target = .worktree(fixture.ref)
            refusal = .ownerUnavailable(reason: SessionsAPI.checkpointRecoveryReason)
        case .busyCheckout:
            target = .workspaceCheckout(id: try await fixture.addCheckout(operation: .archiving, location: .local))
            refusal = .ownerUnavailable(reason: "The Workspace checkout is busy.")
        case .agentNotOnRemoteHost:
            environment.localOnlyAgents = true
            target = .workspaceCheckout(id: try await fixture.addCheckout(operation: .idle, location: .ssh("build")))
            refusal = .agentUnavailable
        case .worktreeClaimedMeanwhile:
            let projects = fixture.core.projects
            let worktree = fixture.worktree
            environment.duringRecoveryCheck = { projects.setOperationState(for: worktree, state: .archiving(projectId: "p")) }
            target = .worktree(fixture.ref)
            refusal = .ownerUnavailable(reason: "Another operation holds the worktree.")
        case .remoteWorktree:
            target = .worktree(fixture.ref)
            refusal = .ownerUnavailable(reason: "Sessions in remote worktrees start from the app.")
        case .recoveryStartsMeanwhile:
            var checks = 0
            environment.duringRecoveryCheck = {
                checks += 1
                environment.recovering = checks > 1
            }
            target = .workspaceCheckout(id: try await fixture.addCheckout(operation: .idle, location: .local))
            refusal = .ownerUnavailable(reason: SessionsAPI.checkpointRecoveryReason)
        case .missingCheckout:
            target = .workspaceCheckout(id: UUID())
            refusal = .ownerUnavailable(reason: WorkspaceAutomationError.checkoutNotFound.message)
        case .agentDisabledMeanwhile:
            environment.duringRecoveryCheck = { environment.agentsEnabled = false }
            target = .worktree(fixture.ref)
            refusal = .agentUnavailable
        case .ownerClaimedAsCreationEnds:
            environment.admitsCreation = false
            target = .workspaceCheckout(id: try await fixture.addCheckout(operation: .idle, location: .local))
            refusal = .ownerUnavailable(reason: "The session's owner was closed or claimed meanwhile.")
        }

        await #expect(throws: refusal) {
            try await fixture.host.sessions.create(target, agentID: "gemini", caller: .app)
        }
        #expect(fixture.host.sessions.list().isEmpty)
    }

    /// Binding a shepherd changes no session row, yet subscribers see the pill.
    @Test func bindingAShepherdRepublishesTheSessionWithItsPill() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let sessions = fixture.host.sessions
        let id = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        try await eventually { await sessions.list().first { $0.id == id }?.streamingState == .idle }
        // With its runtime closed and its lease (and so its heartbeat) given
        // up, nothing of the session itself changes from here on.
        let received = Collected(fixture.host.subscribe())
        let manager = try #require(fixture.core.sessionManagers.values.first)
        manager.closeSession(id: id)
        await manager.releaseWriterLease(sessionId: id)
        try await eventually {
            await received.events.contains { if case .sessionChanged(let s) = $0 { s.id == id && !s.isWriter } else { false } }
        }

        await fixture.core.reviewShepherd.bind(
            sessionID: id, worktreeID: fixture.worktree.id, request: ShepherdFixtures.request(), baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil
        )

        try await eventually {
            await received.events.contains { if case .sessionChanged(let s) = $0 { s.id == id && s.shepherd?.number == "#7" } else { false } }
        }
    }

    /// A headless host shows no banner of its own: it relays the notice to
    /// its subscribers, and reports the session waiting until the user's next
    /// prompt, not when the turn that sent it ends.
    @Test func aNoticeOnAHeadlessHostReachesSubscribersAndHoldsTheSessionWaitingUntilItsNextPrompt() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.core.harness.notifications.notificationAdder = { _ in Issue.record("no system banner on a host") }
        let sessions = fixture.host.sessions
        let id = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        // Its agent runs, as one that sends a notice does.
        try await eventually { await sessions.list().first { $0.id == id }?.streamingState == .idle }
        let subscription = fixture.host.subscribe()
        let received = Collected(subscription)
        try fixture.host.attention.notify(
            "Pick one", title: "Q", needsInput: true,
            from: .worktree(fixture.worktree, sessionID: id, owner: .worktree(fixture.worktree.id)), caller: .session(id: id)
        )
        try await eventually {
            await received.events.contains { if case .notice(let n) = $0 { n.sessionID == id && n.body == "Pick one" } else { false } }
        }
        #expect(sessions.list().first { $0.id == id }?.streamingState == .awaitingInput)
        #expect(await fixture.core.remoteSessionSummaries(tabIndex: { _, _ in nil }).first { $0.id == id }?.status
            == RemoteSessionGateway.stateString(.awaitingInput))
        // While the turn that sent it runs, the session shows it running;
        // once that turn ends, the session still waits.
        let transcript = try #require(fixture.core.sessionManagers.values.first?.liveSession(for: id)?.transcript)
        transcript.streamingState = .streaming
        #expect(sessions.list().first { $0.id == id }?.streamingState == .streaming)
        transcript.streamingState = .idle
        #expect(sessions.list().first { $0.id == id }?.streamingState == .awaitingInput)
        // The next prompt ends the wait: its turn ends idle.
        try await sessions.send(id, prompt: "a", caller: .app)
        try await eventually { await fixture.agent.sent.count { $0.method == "session/prompt" } == 1 }
        try await eventually { await sessions.list().first { $0.id == id }?.streamingState == .idle }
        // A shell's notify, with no session, is not relayed: a change made
        // after it arrives with no notice before it.
        try fixture.host.attention.notify("hi", title: nil, needsInput: false, from: .worktree(fixture.worktree, sessionID: nil, owner: nil), caller: .cli)
        try sessions.rename(id, title: "After", caller: .app)
        try await eventually { await received.events.contains { if case .sessionChanged(let s) = $0 { s.title == "After" } else { false } } }
        #expect(received.events.filter { if case .notice = $0 { true } else { false } }.count == 1)
    }

    /// A headless host relays what would be a system banner: a notification
    /// naming a session it holds as that session's notice, and one naming a
    /// run console or no session as its worktree's, which only a client that
    /// accepts `worktreeNotice` receives.
    @Test func aHeadlessHostRelaysEveryNotificationToTheSessionOrWorktreeItNames() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.host.relayNotifications()
        let id = try await fixture.host.sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        let received = Collected(fixture.host.subscribe())
        let notifications = fixture.core.harness.notifications
        notifications.notifyAlas(
            body: "Merged", title: "Merged", agent: .gemini,
            projectId: fixture.worktree.projectId, worktreeId: fixture.worktree.id, sessionId: id
        )
        notifications.notifyRunScriptFinished(
            scriptName: "test", exitCode: 1,
            projectId: fixture.worktree.projectId, worktreeId: fixture.worktree.id, sessionId: "console-1", runID: "r"
        )

        try await eventually { await received.events.contains {
            if case .worktreeNotice(let n) = $0 { n.worktreeID == fixture.worktree.id && n.title == "test finished" } else { false }
        } }
        #expect(received.notices(of: id).map(\.body) == ["Merged"])

        // A session the host has stored but not loaded is still one a client can open.
        await fixture.core.disposeSessionManager(owner: .worktree(fixture.worktree.id))
        let manager = try fixture.core.sessionManager(for: fixture.worktree)
        await manager.refreshRecentNow()
        #expect(manager.liveSession(for: id) == nil && manager.cachedPersistedSessionRow(id: id) != nil)
        notifications.notifyAlas(
            body: "Ready", title: nil, agent: .gemini,
            projectId: fixture.worktree.projectId, worktreeId: fixture.worktree.id, sessionId: id
        )
        try await eventually { await received.notices(of: id).map(\.body) == ["Merged", "Ready"] }
    }

    enum HostSessionClose: CaseIterable { case archive, disposeOwner }

    /// A stopped runner reports no turn, so a scheduled firing waiting on a
    /// session the host closes ends as stopped rather than waiting hours.
    @Test(arguments: HostSessionClose.allCases)
    func closingAScheduledSessionEndsItsTurnWaitAsStopped(_ close: HostSessionClose) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let sessions = fixture.host.sessions
        let id = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        try await eventually { await sessions.list().first { $0.id == id }?.streamingState == .idle }
        fixture.core.scheduledAgentTurns.expect(id)
        switch close {
        case .archive: try await sessions.archive(id, caller: .app)
        case .disposeOwner: await fixture.core.disposeSessionManager(owner: .worktree(fixture.worktree.id))
        }
        let completion = await fixture.core.scheduledAgentTurns.wait(for: id, timeout: .seconds(10))
        #expect(completion?.result == .cancelled)
    }

    /// A session dropped while a notice holds it waiting comes back no longer waiting.
    @Test func aSessionReplacedWhileANoticeHoldsItWaitingIsNotReportedWaiting() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let sessions = fixture.host.sessions
        let id = try await sessions.create(.worktree(fixture.ref), agentID: "gemini", caller: .app).id
        try await eventually { await sessions.list().first { $0.id == id }?.streamingState == .idle }
        try fixture.host.attention.notify(
            "Pick one", title: nil, needsInput: true,
            from: .worktree(fixture.worktree, sessionID: id, owner: .worktree(fixture.worktree.id)), caller: .session(id: id)
        )
        #expect(sessions.list().first { $0.id == id }?.streamingState == .awaitingInput)
        await fixture.core.disposeSessionManager(owner: .worktree(fixture.worktree.id))
        let manager = try fixture.core.sessionManager(for: fixture.worktree)
        await manager.refreshRecentNow()
        try await sessions.load(id)
        await manager.attach(to: id, freshlyCreated: false)
        try await eventually { await sessions.list().first { $0.id == id }?.streamingState == .idle }
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let core: AlasCoreContext
        let host: AlasHost
        let agent = ACPMockClient()
        let worktree: Worktree
        var ref: WorktreeRef { WorktreeRef(projectID: "p", path: worktree.path.path) }
        var sessionsDatabase: URL { root.appendingPathComponent("sessions.sqlite") }

        init(
            environment: any AlasHostEnvironment = HeadlessHostEnvironment(),
            projectHost: String? = nil,
            otherProjects: [ProjectConfig] = [],
            setupEvaluator: @escaping ACPSessionManager.ACPSetupEvaluator = { _ in .ready }
        ) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-sessions-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var project = ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: .distantPast)
            project.host = projectHost
            let projects = ProjectsManager(persistedProjects: [project] + otherProjects)
            let path = root.appendingPathComponent("feature")
            worktree = Worktree(
                id: Worktree.makeId(path: path), projectId: "p", name: "feature", branch: "feature",
                path: path, status: .clean, lastActivity: .distantPast
            )
            projects.insertOptimisticWorktree(worktree)
            agent.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"sessionCapabilities":{}}"#.utf8) }
            agent.script(method: "session/new") { _ in Data(#"{"sessionId":"agent-1"}"#.utf8) }
            agent.script(method: "session/prompt") { _ in Data("null".utf8) }
            let agent = agent
            let database = root.appendingPathComponent("sessions.sqlite")
            core = AlasCoreContext(
                projects: projects,
                runHistoryStore: nil,
                workspaceStore: WorkspaceStore(url: root.appendingPathComponent("workspaces.json")),
                attentionStore: .scratch(),
                makeSessionManager: { owner, worktree in
                    ACPSessionManager(
                        worktreeId: worktree.id,
                        worktreePath: worktree.path.path,
                        owner: owner,
                        persistence: ACPSessionPersistence(path: database.path),
                        setupEvaluator: setupEvaluator,
                        connectionFactory: { _, _, _ in ACPConnection(client: agent) }
                    )
                },
                environment: environment,
                orchestrationPersistence: ACPOrchestrationPersistence(path: root.appendingPathComponent("orchestration.sqlite").path)
            )
            host = AlasHost(core: core)
        }

        func addCheckout(operation: WorkspaceCheckoutOperation, location: ExecutionLocation) async throws -> UUID {
            let checkout = WorkspaceCheckout(
                workspaceID: nil, fallbackWorkspaceName: "w", executionLocation: location,
                branch: "b", rootPath: root.path, operation: operation, members: []
            )
            try await core.workspaceStore.mutate { $0.checkouts.append(checkout) }
            return checkout.id
        }

        func tearDown() {
            core.sessionManagers.values.forEach { $0.shutdownBackgroundTasks() }
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// A host that can refuse what the tests ask it to.
/// What a subscription delivers, read as it arrives.
@MainActor
private final class Collected {
    private(set) var events: [HostEvent] = []

    init(_ subscription: HostSubscription) {
        Task { [weak self] in
            while let batch = await subscription.next() {
                self?.events += batch
            }
        }
    }

    func states(of id: String) -> [HostSessionState] {
        events.compactMap { if case .sessionState(_, id, let state) = $0 { state } else { nil } }
    }

    func deltas(of id: String) -> [HostTranscriptDelta] {
        events.compactMap { if case .transcript(_, id, let delta) = $0 { delta } else { nil } }
    }

    func notices(of id: String) -> [HostNotice] {
        events.compactMap { if case .notice(let notice) = $0, notice.sessionID == id { notice } else { nil } }
    }
}

@MainActor
private final class RefusingEnvironment: AlasHostEnvironment {
    var recovering = false
    var localOnlyAgents = false
    var admitsCreation = true
    var agentsEnabled = true
    /// Runs while creation waits on the recovery check.
    var duringRecoveryCheck: () -> Void = {}

    func checkpointRecoveryBlocksSessions(owner: SessionOwnerID, in core: AlasCoreContext) async -> Bool {
        duringRecoveryCheck()
        return recovering
    }

    func admitsAgent(_ agentID: String, remoteHost: String?) -> Bool { agentsEnabled && (!localOnlyAgents || remoteHost == nil) }

    func admitsSessionCreation(owner: SessionOwnerID, in core: AlasCoreContext) -> Bool { admitsCreation }
}
