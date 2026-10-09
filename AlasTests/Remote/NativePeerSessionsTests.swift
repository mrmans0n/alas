import Combine
import Foundation
import Testing
@testable import Alas

@MainActor
struct NativePeerSessionsTests {
    private final class FakeLinks: FederatedPeerLinks {
        var sessionCarryingPeers: [FederatedPeerInfo] = []
        var onFederationEvent: (@MainActor (FederatedPeerLinkEvent) -> Void)?
        var sent: [(String, RemoteClientMessage)] = []

        func sendToPeer(_ message: RemoteClientMessage, serverId: String) {
            sent.append((serverId, message))
        }
        func peerSupports(_ capability: String, serverId: String) -> Bool { true }
        func online(_ id: String, name: String) {
            sessionCarryingPeers.append(.init(serverId: id, name: name))
            onFederationEvent?(.availabilityChanged(serverId: id))
        }
        func offline(_ id: String) {
            sessionCarryingPeers.removeAll { $0.serverId == id }
            onFederationEvent?(.availabilityChanged(serverId: id))
        }
        func receive(_ message: RemoteServerMessage, from id: String) {
            onFederationEvent?(.message(serverId: id, message))
        }
        func sent(to id: String) -> [RemoteClientMessage] {
            sent.filter { $0.0 == id }.map { $0.1 }
        }
    }

    private func row(_ id: String, status: String = "idle") -> RemoteSessionSummary {
        .init(id: id, title: id, agentId: "claude", status: status, canDrive: true)
    }

    private func row(_ id: String, changedFiles: Int) -> RemoteSessionSummary {
        .init(id: id, title: id, agentId: "claude", status: "idle", canDrive: true,
              worktree: .init(projectName: "alas", worktreeName: "wt", branch: "feat", path: "/peer/wt",
                              metricsAvailable: true, comparisonRef: "origin/main", commitCount: 1,
                              changedFileCount: changedFiles, addedLines: changedFiles, deletedLines: 0,
                              conflictCount: 0))
    }

    private func listChangesCount(_ links: FakeLinks, _ id: String) -> Int {
        links.sent(to: "B").filter { $0 == .listChanges(sessionId: id) }.count
    }

    private func elicitationField(
        _ key: String,
        type: String,
        required: Bool = true,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        format: String? = nil,
        pattern: String? = nil,
        isSecret: Bool = false,
        options: [RemoteElicitationOption] = [],
        defaultValue: ACPElicitationValue? = nil
    ) -> RemoteElicitationField {
        .init(key: key, type: type, title: key, description: nil, required: required,
              minLength: minLength, maxLength: maxLength, minimum: minimum, maximum: maximum,
              minItems: minItems, maxItems: maxItems, format: format, pattern: pattern,
              isSecret: isSecret, options: options, defaultValue: defaultValue)
    }

    @Test func remotePermissionMapsOntoTheNativeCard() {
        let described = RemotePermissionOption(
            optionId: "allow-once", name: "Allow", kind: "allow_once", description: "For this request only."
        )
        let empty = RemotePermissionOption(optionId: "reject", name: "Reject", kind: "reject_once", description: "")
        let content = ACPPermissionCardContent(payload: RemotePermissionPayload(
            requestId: 1, toolName: "bash", options: [described, empty], title: "Run command?",
            reason: "Builds the project.", defaultToNo: true,
            mcpServerName: "build-tools", commandSummary: "swift build"
        ))

        #expect(content.heading == "Run command?")
        #expect(content.title == "bash")
        #expect(content.summary == "swift build")
        #expect(content.reason == "Builds the project.")
        #expect(content.mcpServerName == "build-tools")
        #expect(content.defaultToNo)
        #expect(content.options.map(\.description) == ["For this request only.", nil])

        let bare = ACPPermissionCardContent(payload: RemotePermissionPayload(
            requestId: 2, toolName: "bash", options: [], title: "", commandSummary: "bash"
        ))
        #expect(bare.heading == nil)
        #expect(bare.summary == nil)
    }

    @Test func structuredPeerRowsDecodeIntoNativeCards() throws {
        func json<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
        let tool = ACPMessage.ToolCall(toolCallId: "tool-1", title: "Run checks",
                                       status: "completed", content: "All checks passed")
        let edit = ACPMessage.FileEdit(path: "Sources/App.swift", added: 2, removed: 1,
                                       newText: "let ready = true")
        let items = [ACPMessage.PlanItem(content: "Update the sidebar", status: "pending")]

        #expect(NativePeerRow(message: .init(
            stableId: "1", kind: "toolCall", text: nil, json: try json(tool), index: 1
        )) == .toolCall(tool))
        #expect(NativePeerRow(message: .init(
            stableId: "2", kind: "fileEdit", text: nil, json: try json(edit), index: 2
        )) == .fileEdit(edit))
        #expect(NativePeerRow(message: .init(
            stableId: "3", kind: "plan", text: nil, json: try json(items), index: 3
        )) == .plan(items))
        #expect(NativePeerRow(message: .init(
            stableId: "4", kind: "thought", text: "Hmm", json: nil, index: 4
        )) == .thought("Hmm"))
    }

    @Test func malformedOrUnknownPeerRowsFallBackToANotice() {
        let broken = NativePeerRow(message: .init(stableId: "1", kind: "toolCall", text: nil, json: "{", index: 1))
        #expect(broken == .systemNotice("Tool call details are unavailable."))

        let unknown = NativePeerRow(message: .init(stableId: "2", kind: "mystery", text: "Body", json: nil, index: 2))
        #expect(unknown == .systemNotice("Body"))
    }

    @Test func thoughtBufferKeepsItsIdentityAndPublishesWhenTextDiverges() {
        let cache = NativePeerRowCache()
        func thought(_ text: String) -> RemoteWireMessage {
            .init(stableId: "t", kind: "thought", text: text, json: nil, index: 0)
        }

        cache.sync([thought("Hel")])
        let buffer = cache.thoughtBuffer(for: "t")
        cache.sync([thought("Hello")])
        #expect(cache.thoughtBuffer(for: "t") === buffer)
        #expect(buffer.value == "Hello")

        // A mounted `ACPThoughtView` observes `buffer`; a divergent replace
        // must reach it through that same object, synchronously.
        var publishes = 0
        let subscription = buffer.objectWillChange.sink { _ in publishes += 1 }
        defer { subscription.cancel() }
        cache.sync([thought("Bye")])
        #expect(cache.thoughtBuffer(for: "t") === buffer)
        #expect(buffer.value == "Bye")
        #expect(publishes == 1)
    }

    @Test func peerQuestionRoundTripsThroughTheNativeInputForm() {
        let payload = RemoteQuestionPayload(requestId: 7, title: "Pick", questions: [
            .init(id: "branch", prompt: "Which branch?",
                  options: [.init(id: "main", label: "main"), .init(id: "dev", label: "dev")],
                  allowMultiple: false),
            .init(id: "targets", prompt: "Targets?",
                  options: [.init(id: "mac", label: "Mac")], allowMultiple: true),
        ])

        let request = NativePeerRequestBridge.userInputRequest(question: payload)
        #expect(request.title == "Pick")
        #expect(request.fields.map(\.key) == ["branch", "targets"])
        #expect(request.fields.map(\.schema.type) == ["string", "array"])
        #expect(request.fields[0].schema.options.map(\.const) == ["main", "dev"])
        guard case .cursor = request.source else {
            Issue.record("Expected a cursor question source")
            return
        }

        let answers = NativePeerRequestBridge.questionAnswers(
            for: .submit(["branch": .string("dev"), "targets": .strings(["mac"])]), question: payload
        )
        #expect(answers == [
            .init(questionId: "branch", selectedOptionIds: ["dev"]),
            .init(questionId: "targets", selectedOptionIds: ["mac"]),
        ])
        #expect(NativePeerRequestBridge.questionAnswers(for: .decline, question: payload) == nil)
        #expect(NativePeerRequestBridge.questionAnswers(for: .cancel, question: payload) == nil)
    }

    @Test func peerElicitationRoundTripsThroughTheNativeInputForm() throws {
        let payload = RemoteElicitationPayload(
            requestId: "form-request", title: "Choose", message: "Pick a value", mode: "form",
            fields: [
                elicitationField("token", type: "string", isSecret: true),
                elicitationField("scopes", type: "array", required: false, minItems: 1,
                                 options: [.init(value: "read", title: "Read", description: "Read only")],
                                 defaultValue: .strings(["read"])),
            ],
            elicitationId: nil, url: nil
        )

        let request = try #require(NativePeerRequestBridge.userInputRequest(elicitation: payload))
        #expect(request.mode == .form)
        #expect(request.title == "Choose")
        #expect(request.fields.map(\.key) == ["token", "scopes"])
        #expect(request.fields[0].schema.isSecret)
        #expect(!request.fields[1].required)
        #expect(request.fields[1].schema.minItems == 1)
        #expect(request.fields[1].schema.options.first?.description == "Read only")
        #expect(request.fields[1].schema.defaultValue?.value as? [String] == ["read"])

        let submit = NativePeerRequestBridge.elicitationReply(for: .submit(["token": .string("abc")]))
        #expect(submit.action == "accept")
        #expect(submit.content == ["token": .string("abc")])
        #expect(NativePeerRequestBridge.elicitationReply(for: .decline).action == "decline")
        #expect(NativePeerRequestBridge.elicitationReply(for: .cancel).content == nil)
    }

    @Test func peerURLElicitationRequiresAnHTTPHost() throws {
        func payload(_ url: String?) -> RemoteElicitationPayload {
            .init(requestId: "url-request", title: nil, message: "Sign in", mode: "url",
                  fields: [], elicitationId: "e1", url: url)
        }

        let valid = try #require(NativePeerRequestBridge.userInputRequest(
            elicitation: payload("https://example.com/auth")
        ))
        guard case .url(let request) = valid.mode else {
            Issue.record("Expected a URL elicitation")
            return
        }
        #expect(request.url.host == "example.com")
        #expect(request.elicitationId == "e1")
        #expect(NativePeerRequestBridge.userInputRequest(elicitation: payload("file:///etc/passwd")) == nil)
        #expect(NativePeerRequestBridge.userInputRequest(elicitation: payload(nil)) == nil)
    }

    @Test func peerPlanRoundTripsThroughTheNativeApprovalPrompt() {
        let payload = RemotePlanPayload(
            requestId: .string("plan-1"), toolCallId: "tool-1", name: "Implement feature",
            overview: "Add peer visibility.", plan: "Render peers.",
            todos: [.init(id: "todo-1", content: "Update the sidebar", status: "pending")],
            isProject: true,
            phases: [.init(name: "Verification", todos: [
                .init(id: "todo-2", content: "Run native tests", status: "pending"),
            ])]
        )

        let params = NativePeerRequestBridge.planParams(payload)
        #expect(params.toolCallId == "tool-1")
        #expect(params.name == "Implement feature")
        #expect(params.todos.map(\.content) == ["Update the sidebar"])
        #expect(params.phases.first?.todos.map(\.id) == ["todo-2"])
        #expect(params.isProject)

        let accepted = NativePeerRequestBridge.planReply(.init(outcome: .accepted(planUri: "alas://plans/tool-1")))
        #expect(accepted.action == "accept")
        #expect(accepted.reason == nil)
        let rejected = NativePeerRequestBridge.planReply(.init(outcome: .rejected(reason: " Needs tests ")))
        #expect(rejected.action == "reject")
        #expect(rejected.reason == "Needs tests")
        #expect(NativePeerRequestBridge.planReply(.init(outcome: .cancelled)).action == "cancel")
    }

    @Test func startSelectionAndStopOwnOneDownstream() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        #expect(federation.isPollingPeerLists)
        links.receive(.sessionList(sessions: [row("s"), row("t")]), from: "B")
        #expect(client.snapshot.groups.first?.sessions.count == 2)
        client.select("B:s")
        #expect(client.selectedSessionId == "B:s")
        #expect(links.sent(to: "B").contains(.subscribe(sessionId: "s")))
        client.select("B:t")
        #expect(links.sent(to: "B").contains(.unsubscribe(sessionId: "s")))
        #expect(links.sent(to: "B").contains(.subscribe(sessionId: "t")))
        client.clearSelection()
        #expect(links.sent(to: "B").contains(.unsubscribe(sessionId: "t")))
        client.stop()
        #expect(!federation.isPollingPeerLists)
        #expect(client.snapshot.groups.isEmpty)
        #expect(client.selectedSessionId == nil)
    }

    @Test func peerWorktreeSelectsOpenTabsRestoresTheLastOneAndFollowsHostCloses() throws {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let client = NativePeerSessions(
            federation: FederatedSessionsProvider(links: links),
            peers: { [.init(serverId: "B", name: "Mac B", state: "online")] }
        )
        client.start()
        func tab(_ id: String, _ index: Int?, updatedAt: Int64 = 1) -> RemoteSessionSummary {
            .init(id: id, title: id, agentId: "claude", status: "idle", canDrive: true,
                  isActive: index != nil, tabIndex: index, worktreeId: "w", updatedAt: updatedAt)
        }
        // The history session is the most recently updated.
        links.receive(.sessionList(sessions: [tab("history", nil, updatedAt: 9), tab("s1", 0), tab("s2", 1)]), from: "B")
        let worktree = try #require(client.snapshot.groups.first?.repos(ordering: .manual).first?.worktrees.first)
        let selection = NativePeerWorktreeSelection(serverId: "B", worktreeId: worktree.id)

        client.selectWorktree(selection)
        #expect(client.selectedSessionId == "B:s1")
        client.selectTab(.session("B:s2"), in: selection)
        client.clearSelection()
        client.selectWorktree(selection)
        #expect(client.selectedSessionId == "B:s2")

        links.receive(.sessionList(sessions: [tab("history", nil, updatedAt: 9), tab("s1", 0), tab("s2", nil)]), from: "B")
        #expect(client.selectedSessionId == "B:s1")
        #expect(client.selectedWorktree == selection)

        links.receive(.sessionList(sessions: [tab("history", nil, updatedAt: 9), tab("s1", nil)]), from: "B")
        #expect(client.selectedSessionId == nil)
        #expect(client.selectedWorktree == selection)
        // Detached once when s2 was picked, and again when the host closed it.
        #expect(links.sent(to: "B").filter { $0 == .unsubscribe(sessionId: "s1") }.count == 2)
    }

    @Test func openingAHistorySessionSelectsItOnceThePeerListsItOpen() throws {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let client = NativePeerSessions(
            federation: FederatedSessionsProvider(links: links),
            peers: { [.init(serverId: "B", name: "Mac B", state: "online")] }
        )
        client.start()
        func session(_ id: String, open: Bool) -> RemoteSessionSummary {
            .init(id: id, title: id, agentId: "claude", status: "idle", canDrive: true,
                  isActive: open, tabIndex: open ? 0 : nil, worktreeId: "w")
        }
        links.receive(.sessionList(sessions: [session("s", open: true), session("h", open: false)]), from: "B")
        let worktree = try #require(client.snapshot.groups.first?.repos(ordering: .manual).first?.worktrees.first)
        client.selectWorktree(NativePeerWorktreeSelection(serverId: "B", worktreeId: worktree.id))

        client.openSession("B:h")
        #expect(links.sent(to: "B").last == .openSessionTab(sessionId: "h"))
        links.receive(.sessionTabActionFailed(sessionId: "h", message: "Session is archived."), from: "B")
        #expect(client.sessionTabError == "Session is archived.")
        #expect(client.selectedSessionId == "B:s")

        // The user moves away and retries; the first attempt's late failure
        // must not cancel the retry.
        client.openSession("B:h")
        client.clearSelection()
        client.select("B:s")
        client.openSession("B:h")
        links.receive(.sessionTabActionFailed(sessionId: "h", message: "Late."), from: "B")
        #expect(client.sessionTabError == nil)
        // Still history: not selected yet.
        links.receive(.sessionList(sessions: [session("s", open: true), session("h", open: false)]), from: "B")
        #expect(client.selectedSessionId == "B:s")
        links.receive(.sessionList(sessions: [session("s", open: true), session("h", open: true)]), from: "B")
        #expect(client.selectedSessionId == "B:h")

        // Refocusing the shown session cancels an open still in flight.
        links.receive(.sessionList(sessions: [session("s", open: true), session("h", open: false)]), from: "B")
        #expect(client.selectedSessionId == "B:s")
        client.openSession("B:h")
        client.openSession("B:s")
        links.receive(.sessionList(sessions: [session("s", open: true), session("h", open: true)]), from: "B")
        #expect(client.selectedSessionId == "B:s")
    }

    @Test func closingTheLastConsoleOfAConsoleOnlyWorktreeLeavesItsEmptyState() throws {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let consoles = NativePeerConsoles(
            send: { _, _ in }, supportsConsoles: { _ in true },
            makeSurface: { _, _, _ in throw CancellationError() }
        )
        let client = NativePeerSessions(
            federation: FederatedSessionsProvider(links: links),
            peers: { [.init(serverId: "B", name: "Mac B", state: "online")] },
            consoles: consoles
        )
        client.start()
        consoles.receive(serverId: "B", .list(consoles: [PeerConsoleSummary(
            consoleId: "c", title: "zsh", worktreeId: "w", projectId: "p",
            projectName: "alas", worktreeName: "w", rows: 24, columns: 80)]))
        let worktree = try #require(client.snapshot.groups.first?.repos(ordering: .manual).first?.worktrees.first)
        let selection = NativePeerWorktreeSelection(serverId: "B", worktreeId: worktree.id)
        client.selectWorktree(selection)
        #expect(client.selectedTab == .console("c"))

        consoles.receive(serverId: "B", .list(consoles: []))

        #expect(client.selectedTab == nil)
        #expect(client.selectedWorktree == selection)
    }

    @Test func aChangedConsoleListRebuildsTheSidebarWithoutASessionListChange() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let consoles = NativePeerConsoles(
            send: { _, _ in }, supportsConsoles: { _ in true },
            makeSurface: { _, _, _ in throw CancellationError() }
        )
        let client = NativePeerSessions(
            federation: FederatedSessionsProvider(links: links),
            peers: { [.init(serverId: "B", name: "Mac B", state: "online")] },
            consoles: consoles
        )
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        let summary = PeerConsoleSummary(
            consoleId: "c", title: "zsh", worktreeId: "w", projectId: "p",
            projectName: "alas", worktreeName: "w", rows: 24, columns: 80)

        consoles.receive(serverId: "B", .list(consoles: [summary]))

        #expect(client.snapshot.groups.first?.consoles == [summary])
    }

    @Test func selectingAPeerSessionLoadsItsWorktreeAndRoutesReplies() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(
            federation: federation,
            peers: {
                [.init(serverId: "B", name: "Mac B", state: "online")]
            },
            comparisonMode: { .branchUpstream }
        )
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        #expect(links.sent(to: "B").contains(
            .listChanges(sessionId: "s", comparisonMode: .branchUpstream)
        ))
        #expect(links.sent(to: "B").contains(
            .listFiles(sessionId: "s", path: nil, comparisonMode: .branchUpstream)
        ))

        links.receive(.changeList(sessionId: "s", comparisonRef: "origin/main", metricsAvailable: true,
                                  files: [], staged: [], unstaged: [], commits: [], truncated: false), from: "B")
        #expect(client.workspace.changes == .loaded(.init(
            comparisonRef: "origin/main", branchFiles: [], staged: [], unstaged: [], commits: [],
            truncated: false, commitsTruncated: false)))

        client.open(.diff(path: "a.swift", stage: nil))
        #expect(links.sent(to: "B").contains(
            .fileDiff(
                sessionId: "s",
                path: "a.swift",
                stage: nil,
                comparisonMode: .branchUpstream
            )
        ))
        // Clicking the selected session again returns to the transcript.
        client.select("B:s")
        #expect(client.workspace.document == nil)
    }

    @Test func worktreeSummaryChangeRefreshesChanges() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s", changedFiles: 1)]), from: "B")
        client.select("B:s")
        // Let the initial request complete, so a later summary change is
        // not racing a request that's still outstanding.
        links.receive(.changeList(sessionId: "s", comparisonRef: nil, metricsAvailable: true,
                                  files: [], staged: [], unstaged: [], commits: [], truncated: false), from: "B")
        let initial = listChangesCount(links, "s")

        links.receive(.sessionList(sessions: [row("s", changedFiles: 1)]), from: "B")
        #expect(listChangesCount(links, "s") == initial)

        links.receive(.sessionList(sessions: [row("s", changedFiles: 2)]), from: "B")
        #expect(listChangesCount(links, "s") == initial + 1)
    }

    @Test func secondChangesRefreshWhileFirstRefreshInFlightQueuesARetry() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s", changedFiles: 1)]), from: "B")
        client.select("B:s")
        links.receive(.changeList(sessionId: "s", comparisonRef: nil, metricsAvailable: true,
                                  files: [], staged: [], unstaged: [], commits: [], truncated: false), from: "B")
        let afterInitialLoad = listChangesCount(links, "s")

        // First refresh: nothing in flight, so this sends.
        links.receive(.sessionList(sessions: [row("s", changedFiles: 2)]), from: "B")
        #expect(listChangesCount(links, "s") == afterInitialLoad + 1)

        // Second refresh while the first is still outstanding: must not send
        // a second request the peer's dedup would silently drop.
        links.receive(.sessionList(sessions: [row("s", changedFiles: 3)]), from: "B")
        #expect(listChangesCount(links, "s") == afterInitialLoad + 1)

        // The first refresh's reply lands — the queued retry must fire now.
        links.receive(.changeList(sessionId: "s", comparisonRef: nil, metricsAvailable: true,
                                  files: [], staged: [], unstaged: [], commits: [], truncated: false), from: "B")
        #expect(listChangesCount(links, "s") == afterInitialLoad + 2)
    }

    @Test func worktreeSummaryChangeAlsoRefreshesTheFileTree() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s", changedFiles: 1)]), from: "B")
        client.select("B:s")
        // Let the root listing finish loading, so a later summary change is
        // re-requesting an already-loaded tree rather than one still in flight.
        links.receive(.fileTree(sessionId: "s", path: nil, nodes: [], truncated: false), from: "B")
        let listFilesCount: () -> Int = {
            links.sent(to: "B").filter { $0 == .listFiles(sessionId: "s", path: nil) }.count
        }
        let initial = listFilesCount()

        links.receive(.sessionList(sessions: [row("s", changedFiles: 2)]), from: "B")
        #expect(listFilesCount() == initial + 1)
    }

    @Test func worktreeSummaryChangeDuringRootLoadQueuesARetryOnReply() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s", changedFiles: 1)]), from: "B")
        client.select("B:s") // the root listFiles request is now in flight

        let listFilesCount: () -> Int = {
            links.sent(to: "B").filter { $0 == .listFiles(sessionId: "s", path: nil) }.count
        }
        let afterSelect = listFilesCount()

        // A summary change arrives before the root listing's reply: blocked
        // by the in-flight load, so nothing new is sent yet.
        links.receive(.sessionList(sessions: [row("s", changedFiles: 2)]), from: "B")
        #expect(listFilesCount() == afterSelect)

        // The (now-stale) reply for the first request arrives — this must
        // queue an immediate retry instead of leaving the tree stale.
        links.receive(.fileTree(sessionId: "s", path: nil, nodes: [], truncated: false), from: "B")
        #expect(listFilesCount() == afterSelect + 1)
    }

    @Test func secondRootRefreshWhileFirstRefreshInFlightQueuesARetry() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s", changedFiles: 1)]), from: "B")
        client.select("B:s")
        // Let the initial root load finish, so the tree is `.loaded` — the
        // case `beginRootLoad()` always permits sending on its own.
        links.receive(.fileTree(sessionId: "s", path: nil, nodes: [], truncated: false), from: "B")

        let listFilesCount: () -> Int = {
            links.sent(to: "B").filter { $0 == .listFiles(sessionId: "s", path: nil) }.count
        }
        let afterInitialLoad = listFilesCount()

        // First refresh: the tree is loaded but nothing is in flight, so this sends.
        links.receive(.sessionList(sessions: [row("s", changedFiles: 2)]), from: "B")
        #expect(listFilesCount() == afterInitialLoad + 1)

        // Second refresh while the first is still outstanding: must not send
        // a second request the peer's dedup would silently drop.
        links.receive(.sessionList(sessions: [row("s", changedFiles: 3)]), from: "B")
        #expect(listFilesCount() == afterInitialLoad + 1)

        // The first refresh's reply lands — the queued retry must fire now.
        links.receive(.fileTree(sessionId: "s", path: nil, nodes: [], truncated: false), from: "B")
        #expect(listFilesCount() == afterInitialLoad + 2)
    }

    @Test func switchingSessionsStartsAFreshWorkspace() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s"), row("t")]), from: "B")
        client.select("B:s")
        // "s" finishes loading and opens a document before the switch, so a
        // missing reset would leave both visibly carried over into "t".
        links.receive(.changeList(sessionId: "s", comparisonRef: "origin/main", metricsAvailable: true,
                                  files: [], staged: [], unstaged: [], commits: [], truncated: false), from: "B")
        client.open(.file(path: "a.swift"))
        #expect(client.workspace.changes != .loading)
        #expect(client.workspace.document != nil)

        client.select("B:t")
        #expect(client.workspace.changes == .loading)
        #expect(client.workspace.document == nil)

        // The earlier session's reply arrives late and must not land on "t".
        links.receive(.changeList(sessionId: "s", comparisonRef: nil, metricsAvailable: true,
                                  files: [], staged: [], unstaged: [], commits: [], truncated: false), from: "B")
        #expect(client.workspace.changes == .loading)
    }

    @Test func transcriptRevisionGapResubscribesUntilANewSnapshotArrives() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        let subscriptionCount: () -> Int = {
            links.sent(to: "B").filter { if case .subscribe = $0 { true } else { false } }.count
        }
        let initialSubscriptions = subscriptionCount()

        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 3, revision: 8), from: "B")
        links.receive(.transcriptDelta(sessionId: "s", streamingState: "streaming", canDrive: false,
                                       upserts: [], epoch: 3, revision: 10), from: "B")
        let subscriptionsAfterGap = subscriptionCount()
        links.receive(.transcriptDelta(sessionId: "s", streamingState: "idle", canDrive: false,
                                       upserts: [], epoch: 3, revision: 11), from: "B")
        #expect(subscriptionsAfterGap == initialSubscriptions + 1)
        #expect(subscriptionCount() == subscriptionsAfterGap)
        #expect(client.transcript?.canDrive == false)

        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 3, revision: 10), from: "B")
        let row = RemoteWireMessage(stableId: "m", kind: "agent", text: "Recovered", json: nil, index: 0)
        links.receive(.transcriptDelta(sessionId: "s", streamingState: "idle", canDrive: true,
                                       upserts: [row], epoch: 3, revision: 11), from: "B")
        #expect(subscriptionCount() == subscriptionsAfterGap)
        #expect(client.transcript?.messages.map(\.stableId) == ["m"])
        #expect(client.transcript?.canDrive == true)
    }

    @Test func offlineRemovesRowsAndAttentionButPreservesDraftUntilForgotten() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        var peers = [RemoteHelloPeer(serverId: "B", name: "Mac B", state: "online")]
        let client = NativePeerSessions(federation: federation, peers: { peers })
        client.start()
        links.receive(.sessionList(sessions: [row("s", status: "awaitingInput")]), from: "B")
        client.select("B:s")
        client.draft = "keep this"
        #expect(client.snapshot.attentionCount == 1)
        links.offline("B")
        peers = [.init(serverId: "B", name: "Mac B", state: "offline")]
        client.refresh()
        #expect(client.workspace.changes == .failed(NativePeerWorkspace.offlineMessage))
        #expect(client.snapshot.attentionCount == 0)
        #expect(client.snapshot.groups.first?.sessions.isEmpty == true)
        #expect(client.selectedSessionId == "B:s")
        #expect(client.transcript?.isClosed == true)
        #expect(client.draft == "keep this")
        peers = []
        client.refresh()
        #expect(client.selectedSessionId == nil)
    }

    @Test func onlyHomeConfirmedDriveCanSendAndRejectionKeepsDraft() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        client.draft = "hello"
        client.sendPrompt()
        #expect(!links.sent(to: "B").contains { if case .sendPrompt = $0 { true } else { false } })
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0), from: "B")
        client.sendPrompt()
        #expect(links.sent(to: "B").contains(.sendPrompt(sessionId: "s", text: "hello", attachments: [], intent: "auto")))
        links.receive(.promptRejected(sessionId: "s"), from: "B")
        #expect(client.draft == "hello")
        #expect(client.deliveryError != nil)
    }

    @Test func selectedSessionResubscribesWhenPeerReturns() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        var peers = [RemoteHelloPeer(serverId: "B", name: "Mac B", state: "online")]
        let client = NativePeerSessions(federation: federation, peers: { peers })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        client.draft = "continue later"
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 4, revision: 0), from: "B")
        links.offline("B")
        peers = [.init(serverId: "B", name: "Mac B", state: "offline")]
        client.refresh()
        #expect(client.transcript?.isClosed == true)

        peers = [.init(serverId: "B", name: "Mac B", state: "online")]
        links.online("B", name: "Mac B")
        let subscriptionsBefore = links.sent(to: "B").filter { $0 == .subscribe(sessionId: "s") }.count
        let changesBefore = listChangesCount(links, "s")
        let listFilesCount: () -> Int = {
            links.sent(to: "B").filter { $0 == .listFiles(sessionId: "s", path: nil) }.count
        }
        let filesBefore = listFilesCount()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        let subscriptionsAfter = links.sent(to: "B").filter { $0 == .subscribe(sessionId: "s") }.count
        #expect(subscriptionsAfter == subscriptionsBefore + 1)
        #expect(listChangesCount(links, "s") > changesBefore)
        // The root file listing was in flight when the peer went offline;
        // reconnecting must not leave it gated on a request that will never
        // get a reply.
        #expect(listFilesCount() > filesBefore)
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0), from: "B")
        #expect(client.transcript?.canDrive == true)
        #expect(client.draft == "continue later")
    }

    @Test func openDocumentSurvivesAReconnectAndReplaysItsRequest() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        var peers = [RemoteHelloPeer(serverId: "B", name: "Mac B", state: "online")]
        let client = NativePeerSessions(federation: federation, peers: { peers })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        client.open(.file(path: "a.swift"))
        #expect(client.workspace.document == .file(path: "a.swift"))

        links.offline("B")
        peers = [.init(serverId: "B", name: "Mac B", state: "offline")]
        client.refresh()
        // Content is unreadable while offline, but the user's place is kept.
        #expect(client.workspace.document == .file(path: "a.swift"))
        #expect(client.workspace.documentContent == .failed(NativePeerWorkspace.offlineMessage))

        peers = [.init(serverId: "B", name: "Mac B", state: "online")]
        links.online("B", name: "Mac B")
        let readFileCount: () -> Int = {
            links.sent(to: "B").filter { $0 == .readFile(sessionId: "s", path: "a.swift") }.count
        }
        let before = readFileCount()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        // Reconnecting must not silently fall back to the transcript.
        #expect(client.workspace.document == .file(path: "a.swift"))
        #expect(readFileCount() == before + 1)
    }

    @Test func reloadWorkspaceQueuesRetriesWhenRequestsAreAlreadyInFlight() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s") // sends the initial listChanges and root listFiles

        let changesCount: () -> Int = { listChangesCount(links, "s") }
        let filesCount: () -> Int = {
            links.sent(to: "B").filter { $0 == .listFiles(sessionId: "s", path: nil) }.count
        }
        let changesAfterSelect = changesCount()
        let filesAfterSelect = filesCount()

        // A manual "Refresh from peer" click while both are still outstanding
        // must not resend yet, but must queue a retry.
        client.reloadWorkspace()
        #expect(changesCount() == changesAfterSelect)
        #expect(filesCount() == filesAfterSelect)

        // The original replies arrive — the queued retries must fire.
        links.receive(.changeList(sessionId: "s", comparisonRef: nil, metricsAvailable: true,
                                  files: [], staged: [], unstaged: [], commits: [], truncated: false), from: "B")
        links.receive(.fileTree(sessionId: "s", path: nil, nodes: [], truncated: false), from: "B")
        #expect(changesCount() == changesAfterSelect + 1)
        #expect(filesCount() == filesAfterSelect + 1)
    }

    @Test func reloadWorkspaceAlsoRefreshesAnOpenDocument() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s", changedFiles: 1)]), from: "B")
        client.select("B:s")
        client.open(.file(path: "a.swift"))
        // Let the initial read complete, so the later summary change finds
        // nothing in flight to gate on.
        links.receive(.fileContents(sessionId: "s", path: "a.swift", text: "old", truncated: false), from: "B")

        let readFileCount: () -> Int = {
            links.sent(to: "B").filter { $0 == .readFile(sessionId: "s", path: "a.swift") }.count
        }
        let afterOpen = readFileCount()

        // The peer edited the open file — its summary changes, and the open
        // document should be re-requested along with changes and files.
        links.receive(.sessionList(sessions: [row("s", changedFiles: 2)]), from: "B")
        #expect(readFileCount() == afterOpen + 1)
    }

    @Test func documentRefreshWhileInFlightQueuesARetry() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s", changedFiles: 1)]), from: "B")
        client.select("B:s")
        client.open(.file(path: "a.swift")) // readFile is now in flight

        let readFileCount: () -> Int = {
            links.sent(to: "B").filter { $0 == .readFile(sessionId: "s", path: "a.swift") }.count
        }
        let afterOpen = readFileCount()

        // Summary changes while the read is still outstanding: must not
        // resend yet (the peer would drop the duplicate), but must queue
        // a retry.
        links.receive(.sessionList(sessions: [row("s", changedFiles: 2)]), from: "B")
        #expect(readFileCount() == afterOpen)

        // The original reply arrives — the queued retry must fire now.
        links.receive(.fileContents(sessionId: "s", path: "a.swift", text: "old", truncated: false), from: "B")
        #expect(readFileCount() == afterOpen + 1)
    }

    @Test func openingADifferentDocumentIsNeverGatedByThePreviousOnesInFlightState() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        client.open(.file(path: "a.swift")) // readFile("a.swift") in flight, no reply yet

        client.open(.file(path: "b.swift"))
        #expect(links.sent(to: "B").contains(.readFile(sessionId: "s", path: "b.swift")))
        #expect(client.workspace.document == .file(path: "b.swift"))
    }

    @Test func returningToAnEarlierDocumentWaitsForItsOriginalReplyRatherThanResending() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")

        client.open(.file(path: "a.swift")) // readFile(a) in flight, no reply yet
        client.open(.file(path: "b.swift")) // readFile(b) in flight, a's reply still pending

        let readFileACount: () -> Int = {
            links.sent(to: "B").filter { $0 == .readFile(sessionId: "s", path: "a.swift") }.count
        }
        let afterFirstOpenOfA = readFileACount()

        // Back to A, before its original reply ever arrived.
        client.open(.file(path: "a.swift"))
        #expect(client.workspace.document == .file(path: "a.swift"))
        // Must not resend — the peer would drop the duplicate by request key.
        #expect(readFileACount() == afterFirstOpenOfA)

        // A's original (now-stale) reply finally arrives — must trigger a
        // fresh request rather than silently standing in as current.
        links.receive(.fileContents(sessionId: "s", path: "a.swift", text: "old", truncated: false), from: "B")
        #expect(readFileACount() == afterFirstOpenOfA + 1)
    }

    @Test func planRejectionRequiresAndTrimsReason() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0), from: "B")
        links.receive(.planRequest(sessionId: "s", payload: .init(
            requestId: .string("plan-1"), toolCallId: "tool-1", name: "Plan", overview: "",
            plan: "", todos: [], isProject: false, phases: []
        )), from: "B")

        client.respondToPlan(requestId: .string("plan-1"), action: "reject", reason: "  \n ")
        #expect(!links.sent(to: "B").contains {
            if case .planResponse(_, .string("plan-1"), _, _) = $0 { return true }
            return false
        })

        client.respondToPlan(requestId: .string("plan-1"), action: "reject", reason: "  Needs a clearer scope.  ")
        #expect(links.sent(to: "B").contains(
            .planResponse(sessionId: "s", requestId: .string("plan-1"),
                          action: "reject", reason: "Needs a clearer scope.")
        ))
    }

    @Test func urlElicitationCannotBeAcceptedBeforeOpeningBrowser() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0), from: "B")
        links.receive(.elicitationRequest(sessionId: "s", payload: .init(
            requestId: "url-request", title: nil, message: "Sign in", mode: "url", fields: [],
            elicitationId: "oauth", url: "https://example.com/connect"
        )), from: "B")

        client.respondToElicitation(requestId: "url-request", action: "accept", content: [:])

        #expect(!links.sent(to: "B").contains {
            if case .elicitationResponse(_, "url-request", "accept", _) = $0 { return true }
            return false
        })

        var requestedURL: URL?
        var finishOpening: (@MainActor (Bool) -> Void)?
        var didOpen = false
        client.openElicitationURL(requestId: "url-request", openURL: { url, finish in
            requestedURL = url
            finishOpening = finish
        }, completion: { didOpen = $0 })
        #expect(requestedURL?.absoluteString == "https://example.com/connect")
        finishOpening?(false)
        #expect(!didOpen)
        #expect(!links.sent(to: "B").contains {
            if case .elicitationResponse(_, "url-request", "accept", _) = $0 { return true }
            return false
        })

        client.openElicitationURL(requestId: "url-request", openURL: { url, finish in
            requestedURL = url
            finishOpening = finish
        }, completion: { didOpen = $0 })
        finishOpening?(true)
        #expect(didOpen)
        #expect(links.sent(to: "B").contains(
            .elicitationResponse(sessionId: "s", requestId: "url-request", action: "accept", content: [:])
        ))
    }

    @Test func formElicitationCanBeCancelled() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0), from: "B")
        links.receive(.elicitationRequest(sessionId: "s", payload: .init(
            requestId: "form-request", title: "Choose", message: "Pick a value", mode: "form", fields: [],
            elicitationId: nil, url: nil
        )), from: "B")

        client.respondToElicitation(requestId: "form-request", action: "cancel")

        #expect(links.sent(to: "B").contains(
            .elicitationResponse(sessionId: "s", requestId: "form-request", action: "cancel", content: nil)
        ))
    }

    @Test(arguments: [false, true])
    func stopControlIsShownForEveryActivePeerState(hasCancellableBackgroundWork: Bool) {
        #expect(NativePeerSessionControls.showsStop(for: "streaming"))
        #expect(NativePeerSessionControls.showsStop(for: "awaitingPermission"))
        #expect(NativePeerSessionControls.showsStop(for: "awaitingInput"))
        #expect(NativePeerSessionControls.showsStop(for: "idle", hasCancellableBackgroundWork: hasCancellableBackgroundWork)
            == hasCancellableBackgroundWork)
    }

    @Test func pendingPromptCannotBeRoutedTwiceBeforeConfirmation() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0), from: "B")
        client.draft = "run the checks"

        client.sendPrompt()
        client.sendPrompt()

        #expect(links.sent(to: "B").filter {
            if case .sendPrompt(_, "run the checks", _, _) = $0 { return true }
            return false
        }.count == 1)
        #expect(client.isPromptPending)
    }

    @Test func olderTranscriptPageCannotConfirmPendingPrompt() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        let tail = RemoteWireMessage(stableId: "agent-1", kind: "agent", text: "Earlier response", json: nil, index: 1)
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [tail], firstIndex: 1, totalCount: 2, epoch: 1, revision: 0), from: "B")
        client.draft = "run the checks"

        client.sendPrompt()
        let historicalDuplicate = RemoteWireMessage(
            stableId: "old-user", kind: "user", text: "run the checks", json: nil, index: 0
        )
        links.receive(.transcriptPage(sessionId: "s", epoch: 1, firstIndex: 0,
                                      messages: [historicalDuplicate]), from: "B")

        #expect(client.isPromptPending)
        #expect(client.draft == "run the checks")

        let deliveredPrompt = RemoteWireMessage(
            stableId: "new-user", kind: "user", text: "run the checks", json: nil, index: 2
        )
        links.receive(.transcriptDelta(sessionId: "s", streamingState: "streaming", canDrive: true,
                                       upserts: [deliveredPrompt], epoch: 1, revision: 1), from: "B")
        #expect(!client.isPromptPending)
        #expect(client.draft.isEmpty)
    }

    @Test func olderTranscriptFetchIsSingleFlight() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        let tail = RemoteWireMessage(
            stableId: "agent-180", kind: "agent", text: "Latest response", json: nil, index: 180
        )
        links.receive(.transcriptSnapshot(
            sessionId: "s", streamingState: "idle", canDrive: true,
            messages: [tail], firstIndex: 180, totalCount: 181, epoch: 1, revision: 0
        ), from: "B")

        client.fetchOlder()
        client.fetchOlder()

        #expect(links.sent(to: "B").filter {
            $0 == .fetchOlder(
                sessionId: "s", beforeIndex: 180, limit: RemoteTranscriptSync.tailWindow
            )
        }.count == 1)

        let older = RemoteWireMessage(
            stableId: "agent-90", kind: "agent", text: "Older response", json: nil, index: 90
        )
        links.receive(.transcriptPage(
            sessionId: "s", epoch: 1, firstIndex: 90, messages: [older]
        ), from: "B")
        client.fetchOlder()

        #expect(links.sent(to: "B").filter {
            $0 == .fetchOlder(
                sessionId: "s", beforeIndex: 90, limit: RemoteTranscriptSync.tailWindow
            )
        }.count == 1)
    }

    @Test func pagedPeerTranscriptFoldsFinishedWorkByLocalPosition() throws {
        func json<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
        func tool(_ id: String, status: String, index: Int) throws -> RemoteWireMessage {
            let call = ACPMessage.ToolCall(toolCallId: id, title: "Read file", status: status, content: "")
            return .init(stableId: id, kind: "toolCall", text: nil, json: try json(call), index: index)
        }
        // A paged window: wire indices start mid-history, so folding by
        // them instead of local position would read past the array.
        let messages: [RemoteWireMessage] = [
            .init(stableId: "u1", kind: "user", text: "Look around", json: nil, index: 90),
            try tool("t1", status: "completed", index: 91),
            try tool("t2", status: "completed", index: 92),
            .init(stableId: "a1", kind: "agent", text: "Done", json: nil, index: 93),
            .init(stableId: "u2", kind: "user", text: "Again", json: nil, index: 94),
            try tool("t3", status: "in_progress", index: 95),
        ]
        let cache = NativePeerRowCache()

        let rows = NativePeerTranscriptFold.renderRows(
            messages: messages, proxies: cache.proxies(for: messages),
            isTurnActive: true, enabled: true
        )

        #expect(rows.map(\.id) == ["u1", "tcg-t1", "a1", "u2", "t3"])
        guard case .toolCallGroup(let group) = rows[1] else {
            Issue.record("Expected the finished work to fold into one group")
            return
        }
        #expect(group.members.map(\.index) == [1, 2])
        #expect(group.kind == .completedTurn(duration: nil))
    }

    private func projectRow(_ id: String, projectId: String = "p", worktreeId: String = "w1") -> RemoteSessionSummary {
        .init(id: id, title: id, agentId: "claude", status: "idle", canDrive: true,
              projectId: projectId, worktreeId: worktreeId,
              worktree: .init(projectName: "alas", worktreeName: "wt", branch: "feat", path: "/peer/\(worktreeId)",
                              metricsAvailable: false, comparisonRef: nil, commitCount: 0,
                              changedFileCount: 0, addedLines: 0, deletedLines: 0, conflictCount: 0))
    }

    private func worktreeOption(_ id: String, projectId: String?, projectName: String = "alas") -> RemoteWorktreeOption {
        .init(id: id, projectName: projectName, worktreeName: id, branch: id, path: "/peer/\(id)",
              metricsAvailable: false, comparisonRef: nil, commitCount: 0, changedFileCount: 0,
              addedLines: 0, deletedLines: 0, conflictCount: 0, projectId: projectId)
    }

    private func startedClientWithPeerRepo() -> (FakeLinks, NativePeerSessions, NativePeerGroup, NativePeerRepoGroup) {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [projectRow("s")]), from: "B")
        let peer = client.snapshot.groups[0]
        let repo = peer.repos(ordering: .lastUpdateDesc)[0]
        return (links, client, peer, repo)
    }

    @Test func aCreatedPeerSessionIsSelectedOnceItsRowArrives() throws {
        let (links, client, peer, repo) = startedClientWithPeerRepo()
        client.beginNewSession(peer: peer, repo: repo)
        #expect(links.sent(to: "B").contains(.listWorktrees))
        #expect(links.sent(to: "B").contains(.listAgents))

        links.receive(.worktreeList(worktrees: [worktreeOption("w1", projectId: "p"),
                                                worktreeOption("w9", projectId: "other")]), from: "B")
        links.receive(.agentList(agents: [.init(id: "claude", name: "Claude", isDefault: true)]), from: "B")
        #expect(client.newSession?.worktrees?.map(\.id) == ["w1"])
        #expect(client.newSession?.isLoading == false)

        client.createNewSession(worktreeId: "w1", agentId: "claude", modelId: "opus", effortId: "high")
        #expect(client.newSession?.phase == .creating)
        #expect(links.sent(to: "B").last
            == .createSession(worktreeId: "w1", agentId: "claude", modelId: "opus", effortId: "high"))

        links.receive(.sessionCreated(session: projectRow("new")), from: "B")
        #expect(client.newSession == nil)
        links.receive(.sessionList(sessions: [projectRow("new"), projectRow("s")]), from: "B")
        #expect(client.selectedSessionId == "B:new")
    }

    @Test func aWorktreesNewSessionPreselectsItEvenWithNoTabOpen() throws {
        let (links, client, _, _) = startedClientWithPeerRepo()
        let history = RemoteSessionSummary(id: "s", title: "s", agentId: "claude", status: "idle", canDrive: true,
                                           isActive: false, projectId: "p", worktreeId: "w1",
                                           worktree: projectRow("s").worktree)
        links.receive(.sessionList(sessions: [history]), from: "B")
        let worktree = try #require(client.snapshot.groups.first?.repos(ordering: .manual).first?.worktrees.first)
        let selection = NativePeerWorktreeSelection(serverId: "B", worktreeId: worktree.id)
        // Its only session is history, so selecting the worktree opens no tab.
        client.selectWorktree(selection)
        #expect(client.selectedTab == nil)

        client.beginNewSession(in: selection)

        #expect(client.newSession?.projectId == "p")
        #expect(client.newSessionDefaultWorktreeId == "w1")
        links.offline("B")
        #expect(client.newSessionTarget(in: selection) == nil)
    }

    @Test func aRefusedCreateKeepsTheSheetWithTheReason() {
        let (links, client, peer, repo) = startedClientWithPeerRepo()
        client.beginNewSession(peer: peer, repo: repo)
        client.createNewSession(worktreeId: "w1", agentId: "claude", modelId: nil, effortId: nil)
        links.receive(.createSessionFailed(message: "Agent is no longer available."), from: "B")
        #expect(client.newSession?.phase == .failed("Agent is no longer available."))
    }

    @Test func aWorktreeCreatedOnThePeerSelectsItsSession() {
        let (links, client, peer, repo) = startedClientWithPeerRepo()
        client.beginNewSession(peer: peer, repo: repo)
        #expect(links.sent(to: "B").contains(.listBranches(projectId: "p")))
        links.receive(.branchList(projectId: "p", branches: ["dev", "main"], preferredBase: "main"), from: "B")
        #expect(client.newSession?.branches == .loaded(names: ["dev", "main"], preferredBase: "main"))

        client.createNewWorktreeSession(
            base: "main", branch: "feature/x", agentId: "claude", modelId: "opus", effortId: "high")
        #expect(client.newSession?.phase == .creating)
        #expect(links.sent(to: "B").last == .createWorktreeSession(
            projectId: "p", base: "main", branch: "feature/x", agentId: "claude",
            modelId: "opus", effortId: "high"))

        links.receive(.worktreeSessionCreated(session: projectRow("new", worktreeId: "w2")), from: "B")
        #expect(client.newSession == nil)
        links.receive(.sessionList(sessions: [projectRow("new", worktreeId: "w2"), projectRow("s")]), from: "B")
        #expect(client.selectedSessionId == "B:new")
    }

    @Test func aWorktreeCreatedWithoutItsSessionIsOfferedForRetry() {
        let (links, client, peer, repo) = startedClientWithPeerRepo()
        client.beginNewSession(peer: peer, repo: repo)
        links.receive(.worktreeList(worktrees: [worktreeOption("w1", projectId: "p")]), from: "B")
        client.createNewWorktreeSession(base: "main", branch: "feature/x", agentId: "claude", modelId: nil, effortId: nil)
        links.sent.removeAll()

        let message = "Worktree created, but the session could not be created."
        links.receive(.worktreeSessionCreationFailed(stage: .session, message: message, worktreeId: "w2"), from: "B")

        #expect(client.newSession?.phase == .failed(message))
        #expect(client.newSession?.recoveredWorktreeId == "w2")
        #expect(links.sent(to: "B") == [.listWorktrees])
    }

    @Test(arguments: [
        ("main", "feature/x", true),
        ("gone", "feature/x", false),   // the peer only accepts a base it lists
        ("main", "", false),
        ("main", "bad name", false),
    ] as [(String, String, Bool)])
    func aNewPeerWorktreeNeedsAListedBaseAndAValidBranch(base: String, branch: String, allowed: Bool) {
        let branches = NativePeerNewSession.Branches.loaded(names: ["dev", "main"], preferredBase: "main")
        #expect(NativePeerNewSession.canCreateWorktree(base: base, branch: branch, branches: branches) == allowed)
        #expect(!NativePeerNewSession.canCreateWorktree(base: base, branch: branch, branches: .failed("no git")))
    }

    @Test(arguments: [
        ("main", "main"),
        ("trunk", "dev"),   // a preferred base the peer does not list falls back to its first branch
    ] as [(String, String)])
    func aNewPeerWorktreePreselectsThePeersPreferredBase(preferred: String, expected: String) {
        let branches = NativePeerNewSession.Branches.loaded(names: ["dev", "main"], preferredBase: preferred)
        #expect(NativePeerNewSession.preselectedBase(in: branches) == expected)
    }

    @Test func repliesForACancelledSheetAreIgnored() {
        let (links, client, peer, repo) = startedClientWithPeerRepo()
        client.beginNewSession(peer: peer, repo: repo)
        client.cancelNewSession()
        client.beginNewSession(peer: peer, repo: repo)
        // Answers the first sheet's request; the second's is sent next.
        links.receive(.worktreeList(worktrees: [worktreeOption("w1", projectId: "p")]), from: "B")
        #expect(client.newSession?.worktrees == nil)
        links.receive(.worktreeList(worktrees: [worktreeOption("w1", projectId: "p")]), from: "B")
        #expect(client.newSession?.worktrees?.map(\.id) == ["w1"])
    }

    @Test(arguments: [
        (true, ["w1"]),          // matches on projectId
        (false, ["w1", "w2"]),   // older peer without projectIds: falls back to project name
    ] as [(Bool, [String])])
    func newSessionWorktreesBelongToTheClickedRepo(optionsCarryProjectIds: Bool, expected: [String]) {
        let options = [
            worktreeOption("w1", projectId: optionsCarryProjectIds ? "p" : nil),
            worktreeOption("w2", projectId: optionsCarryProjectIds ? "q" : nil),
            worktreeOption("w3", projectId: optionsCarryProjectIds ? "r" : nil, projectName: "other"),
        ]
        #expect(NativePeerNewSession.worktrees(options, projectId: "p", repoName: "alas").map(\.id) == expected)
    }

    @Test func newSessionPreselectsTheSelectedWorktreeThenTheDefaultAgent() {
        let options = [worktreeOption("w1", projectId: "p"), worktreeOption("w2", projectId: "p")]
        #expect(NativePeerNewSession.preselectedWorktreeId(in: options, selectedWorktreeId: "w2") == "w2")
        #expect(NativePeerNewSession.preselectedWorktreeId(in: options, selectedWorktreeId: "elsewhere") == "w1")
        let agents: [RemoteAgentOption] = [.init(id: "codex", name: "Codex", isDefault: false),
                                           .init(id: "claude", name: "Claude", isDefault: true)]
        #expect(NativePeerNewSession.preselectedAgentId(in: agents) == "claude")
        #expect(NativePeerNewSession.preselectedAgentId(in: Array(agents.prefix(1))) == "codex")
    }

    @Test(arguments: [
        (true, true, true, true, false),
        (true, false, true, false, false),
        (false, true, false, true, false),
        (false, false, false, false, true),  // nothing remembered: chips hidden, hint shown
    ] as [(Bool, Bool, Bool, Bool, Bool)])
    func newSessionShowsOnlyTheChipsThePeerRemembers(
        hasModels: Bool, hasEfforts: Bool, showsModel: Bool, showsEffort: Bool, showsHint: Bool
    ) throws {
        let agent = RemoteAgentOption(
            id: "claude", name: "Claude", isDefault: true,
            models: hasModels ? [RemoteModelOption(id: "opus", name: "Opus")] : nil,
            efforts: hasEfforts ? [RemoteEffortOption(id: "high", name: "High")] : nil)
        let visibility = try #require(NativePeerNewSession.chipVisibility(for: agent))
        #expect(visibility.showsModel == showsModel)
        #expect(visibility.showsEffort == showsEffort)
        #expect(visibility.showsDefaultsHint == showsHint)
        #expect(NativePeerNewSession.chipVisibility(for: nil) == nil)
    }

    @Test func newSessionSheetRecoversWhenThePeerComesBack() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        var peerState = "online"
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: peerState)]
        })
        client.start()
        links.receive(.sessionList(sessions: [projectRow("s")]), from: "B")
        let peer = client.snapshot.groups[0]
        client.beginNewSession(peer: peer, repo: peer.repos(ordering: .lastUpdateDesc)[0])

        peerState = "offline"
        links.offline("B")
        client.refresh()
        #expect(client.newSession?.phase == .failed(NativePeerSessions.peerUnavailableMessage))

        peerState = "online"
        links.sent.removeAll()
        links.online("B", name: "Mac B")
        client.refresh()
        #expect(client.newSession?.phase == .editing)
        #expect(links.sent(to: "B").contains(.listWorktrees))
        #expect(links.sent(to: "B").contains(.listAgents))
    }

    @Test func aCreateInterruptedByThePeerGoingOfflineCanBeRetried() {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        var peerState = "online"
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: peerState)]
        })
        client.start()
        links.receive(.sessionList(sessions: [projectRow("s")]), from: "B")
        let peer = client.snapshot.groups[0]
        client.beginNewSession(peer: peer, repo: peer.repos(ordering: .lastUpdateDesc)[0])
        client.createNewSession(worktreeId: "w1", agentId: "claude", modelId: nil, effortId: nil)
        #expect(client.newSession?.phase == .creating)

        peerState = "offline"
        links.offline("B")
        client.refresh()
        #expect(client.newSession?.phase == .failed(NativePeerSessions.peerUnavailableMessage))

        peerState = "online"
        links.online("B", name: "Mac B")
        client.refresh()
        #expect(client.newSession?.phase == .editing)
    }

    /// `nil` leaves the peer selection entirely, the way picking a local
    /// worktree does.
    @Test(arguments: ["B:s", nil] as [String?])
    func aCreatedSessionDoesNotStealSelectionAfterTheUserNavigates(to destination: String?) {
        let (links, client, peer, repo) = startedClientWithPeerRepo()
        client.beginNewSession(peer: peer, repo: repo)
        client.createNewSession(worktreeId: "w1", agentId: "claude", modelId: nil, effortId: nil)
        links.receive(.sessionCreated(session: projectRow("new")), from: "B")
        if let destination { client.select(destination) } else { client.clearSelection() }
        links.receive(.sessionList(sessions: [projectRow("new"), projectRow("s")]), from: "B")
        #expect(client.selectedSessionId == destination)
    }
}
