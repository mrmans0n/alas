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

    private func startedPeerClient() -> (FakeLinks, NativePeerSessions) {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let client = NativePeerSessions(
            federation: FederatedSessionsProvider(links: links),
            peers: {
                links.sessionCarryingPeers.map {
                    .init(serverId: $0.serverId, name: $0.name, state: "online")
                }
            }
        )
        client.start()
        return (links, client)
    }

    @Test func peerProjectInventoryGroupsProjectsWithTheirSessions() throws {
        let (links, client) = startedPeerClient()
        defer { client.stop() }
        links.receive(.projectList(projects: [
            .init(id: "empty", name: "Empty project"),
            .init(id: "active", name: "Active project")
        ]), from: "B")
        links.receive(.sessionList(sessions: [
            .init(id: "s", title: "Session", agentId: "claude", status: "idle", canDrive: true,
                  projectId: "active", worktreeId: "w",
                  worktree: .init(projectName: "Old name", worktreeName: "main", branch: "main",
                                  path: "/active", metricsAvailable: false, comparisonRef: nil,
                                  commitCount: 0, changedFileCount: 0, addedLines: 0,
                                  deletedLines: 0, conflictCount: 0))
        ]), from: "B")

        let repos = try #require(client.snapshot.groups.first).repos(ordering: .manual)
        #expect(Set(repos.compactMap(\.projectId)) == ["empty", "active"])
        let empty = try #require(repos.first { $0.projectId == "empty" })
        #expect(empty.name == "Empty project")
        #expect(empty.worktrees.isEmpty)
        let active = try #require(repos.first { $0.projectId == "active" })
        #expect(active.name == "Active project")
        #expect(active.worktrees.first?.sessions.map(\.id) == ["B:s"])
    }

    @Test func newSessionCanStartFromAnInventoryOnlyPeerProject() throws {
        let (links, client) = startedPeerClient()
        defer { client.stop() }
        links.receive(.projectList(projects: [.init(id: "empty", name: "Empty project")]), from: "B")

        let peer = try #require(client.snapshot.groups.first)
        let repo = try #require(peer.repos(ordering: .manual).first)
        client.beginNewSession(peer: peer, repo: repo)

        #expect(client.newSession?.projectId == "empty")
    }

    @Test func peerProjectInventoryRenameUpdatesItsSidebarLabel() throws {
        let (links, client) = startedPeerClient()
        defer { client.stop() }
        links.receive(.projectList(projects: [.init(id: "empty", name: "Old name")]), from: "B")
        links.receive(.projectList(projects: [.init(id: "empty", name: "Renamed project")]), from: "B")

        let repo = try #require(client.snapshot.groups.first?.repos(ordering: .manual).first)
        #expect(repo.name == "Renamed project")
    }

    @Test func reconnectingPeerReplacesItsProjectInventory() throws {
        let (links, client) = startedPeerClient()
        defer { client.stop() }
        links.receive(.projectList(projects: [.init(id: "old", name: "Old project")]), from: "B")
        links.offline("B")
        links.online("B", name: "Mac B")
        client.refresh()

        #expect(client.snapshot.groups.first?.repos(ordering: .manual).isEmpty == true)
        links.receive(.projectList(projects: [.init(id: "fresh", name: "Fresh project")]), from: "B")
        #expect(client.snapshot.groups.first?.repos(ordering: .manual).compactMap(\.projectId) == ["fresh"])
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

    /// Open session `s` is selected; `h` is history in the same worktree.
    private func clientWithHistorySession() throws -> (FakeLinks, NativePeerSessions) {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let client = NativePeerSessions(
            federation: FederatedSessionsProvider(links: links),
            peers: { [.init(serverId: "B", name: "Mac B", state: "online")] }
        )
        client.start()
        links.receive(historyList(hOpen: false), from: "B")
        let worktree = try #require(client.snapshot.groups.first?.repos(ordering: .manual).first?.worktrees.first)
        client.selectWorktree(NativePeerWorktreeSelection(serverId: "B", worktreeId: worktree.id))
        return (links, client)
    }

    private func historyList(hOpen: Bool) -> RemoteServerMessage {
        func session(_ id: String, tab: Int?) -> RemoteSessionSummary {
            .init(id: id, title: id, agentId: "claude", status: "idle", canDrive: true,
                  isActive: tab != nil, tabIndex: tab, worktreeId: "w")
        }
        return .sessionList(sessions: [session("s", tab: 0), session("h", tab: hOpen ? 1 : nil)])
    }

    @Test func openingAHistorySessionSelectsItOnceThePeerListsItOpen() throws {
        let (links, client) = try clientWithHistorySession()
        client.openSession("B:h")
        #expect(links.sent(to: "B").last == .openSessionTab(sessionId: "h"))
        #expect(client.selectedSessionId == "B:s")
        links.receive(historyList(hOpen: true), from: "B")
        #expect(client.selectedSessionId == "B:h")
    }

    @Test func aRefusedTabOpenShowsTheReasonAndKeepsTheSelection() throws {
        let (links, client) = try clientWithHistorySession()
        client.openSession("B:h")
        links.receive(.sessionTabActionFailed(sessionId: "h", message: "Session is archived."), from: "B")
        #expect(client.sessionTabError == "Session is archived.")
        #expect(client.selectedSessionId == "B:s")
    }

    @Test func aRetriedTabOpenIgnoresTheEarlierAttemptsLateFailure() throws {
        let (links, client) = try clientWithHistorySession()
        client.openSession("B:h")
        client.clearSelection()
        client.select("B:s")
        client.openSession("B:h")
        links.receive(.sessionTabActionFailed(sessionId: "h", message: "Late."), from: "B")
        #expect(client.sessionTabError == nil)
        links.receive(historyList(hOpen: true), from: "B")
        #expect(client.selectedSessionId == "B:h")
    }

    @Test func refocusingTheShownSessionCancelsAPendingTabOpen() throws {
        let (links, client) = try clientWithHistorySession()
        client.openSession("B:h")
        client.openSession("B:s")
        links.receive(historyList(hOpen: true), from: "B")
        #expect(client.selectedSessionId == "B:s")
    }

    /// Open sessions `s` and `h`, with `h` selected and asked to close.
    private func clientClosingSession() throws -> (FakeLinks, NativePeerSessions) {
        let (links, client) = try clientWithHistorySession()
        links.receive(historyList(hOpen: true), from: "B")
        client.select("B:h")
        client.closeSessionTab("B:h")
        return (links, client)
    }

    @Test func aClosingTabIsAskedForOnceAndStaysUntilThePeerDropsIt() throws {
        let (links, client) = try clientClosingSession()
        client.closeSessionTab("B:h")
        #expect(links.sent(to: "B").filter { $0 == .closeSessionTab(sessionId: "h") }.count == 1)
        #expect(client.closingSessionIds == ["B:h"])
        #expect(client.selectedSessionId == "B:h")
    }

    @Test func aClosedTabLeavingThePeerListSelectsItsNeighbour() throws {
        let (links, client) = try clientClosingSession()
        links.receive(.sessionTabActionSucceeded(sessionId: "h"), from: "B")
        links.receive(historyList(hOpen: false), from: "B")
        #expect(client.closingSessionIds.isEmpty)
        #expect(client.selectedSessionId == "B:s")
    }

    @Test func aRefusedTabCloseClearsTheMarkAndShowsTheReason() throws {
        let (links, client) = try clientClosingSession()
        links.receive(.sessionTabActionFailed(sessionId: "h", message: "This session is archived."), from: "B")
        #expect(client.closingSessionIds.isEmpty)
        #expect(client.tabCloseError == "This session is archived.")
        #expect(client.sessionTabError == nil)
        #expect(client.selectedSessionId == "B:h")
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

    private func drivenClient(canDrive: Bool) -> (FakeLinks, NativePeerSessions) {
        let links = FakeLinks()
        links.online("B", name: "Mac B")
        let federation = FederatedSessionsProvider(links: links)
        let client = NativePeerSessions(federation: federation, peers: {
            [.init(serverId: "B", name: "Mac B", state: "online")]
        })
        client.start()
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        client.select("B:s")
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: canDrive,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0), from: "B")
        return (links, client)
    }

    @Test func chipChangeWhileNotWriterTakesOverFirst() {
        let (links, client) = drivenClient(canDrive: false)
        let spec = ChipSpec(source: .configOption(id: "effort"), options: [], currentId: "low")
        client.selectChip(spec, itemId: "high")
        let drive = links.sent(to: "B").filter {
            switch $0 { case .takeOver, .setConfigOption: true
            default: false }
        }
        #expect(drive == [.takeOver(sessionId: "s"),
                          .setConfigOption(sessionId: "s", configId: "effort", value: .string("high"))])
    }

    @Test(arguments: [
        (ChipSpec.Source.model, "opus", RemoteClientMessage.setModel(sessionId: "s", modelId: "opus")),
        (ChipSpec.Source.mode, "plan", RemoteClientMessage.setMode(sessionId: "s", modeId: "plan")),
        (ChipSpec.Source.configOption(id: "model"), "gpt",
         RemoteClientMessage.setConfigOption(sessionId: "s", configId: "model", value: .string("gpt"))),
    ])
    func chipSourcesDispatchTheirVerb(source: ChipSpec.Source, itemId: String, expected: RemoteClientMessage) {
        let (links, client) = drivenClient(canDrive: true)
        client.selectChip(ChipSpec(source: source, options: [], currentId: nil), itemId: itemId)
        let verbs = links.sent(to: "B").filter {
            switch $0 { case .setModel, .setMode, .setConfigOption, .takeOver: true
            default: false }
        }
        #expect(verbs == [expected])
    }

    @Test func chipsAndSteeringSurviveFederationRescoping() {
        let (links, client) = drivenClient(canDrive: true)
        let chips = RemoteChipState(model: nil, thinking: nil, mode: nil, parameters: [], booleans: [],
                                    autoRun: "supported")
        links.receive(.sessionConfig(RemoteSessionConfig(
            sessionId: "s", models: [], modes: [], currentModel: nil, currentMode: nil, autoRunEnabled: false,
            acceptsImages: false, chips: chips, supportsSteering: true)), from: "B")
        #expect(client.transcript?.config?.chips == chips)
        #expect(client.transcript?.config?.supportsSteering == true)
    }

    @Test func olderHostConfigFallsBackToLegacyModelAndModeChips() {
        let config = RemoteSessionConfig(sessionId: "s", models: [.init(id: "opus", name: "Opus")],
                                         modes: [.init(id: "plan", name: "Plan")], currentModel: "opus",
                                         currentMode: "plan", autoRunEnabled: false, acceptsImages: false)
        let state = NativePeerComposerState.chipState(from: config)
        #expect(state.models?.source == .model)
        #expect(state.models?.currentId == "opus")
        #expect(state.mode?.source == .mode)
        #expect(state.thinking == nil)
    }

    @Test func unknownChipSourceIsHiddenAndUnknownPresentationIsStandard() {
        var config = RemoteSessionConfig(sessionId: "s", models: [], modes: [], currentModel: nil,
                                         currentMode: nil, autoRunEnabled: false, acceptsImages: false)
        let future = RemoteChip(source: "telepathy", configId: nil, options: [], currentId: nil)
        let known = RemoteChip(source: "config", configId: "ctx",
                               options: [.init(id: "1m", name: "1M", description: nil, kind: nil)], currentId: "1m")
        config.chips = RemoteChipState(model: future, thinking: nil, mode: nil,
                                       parameters: [.init(id: "ctx", label: "Context", presentation: "hologram", chip: known)],
                                       booleans: [], autoRun: "supported")
        let state = NativePeerComposerState.chipState(from: config)
        #expect(state.models == nil)
        #expect(state.parameters.map(\.presentation) == [.standard])
    }

    @Test func queuedSendIsConfirmedByQueueState() {
        let (links, client) = drivenClient(canDrive: true)
        links.receive(.transcriptDelta(sessionId: "s", streamingState: "streaming", canDrive: true, upserts: [],
                                       epoch: 1, revision: 1), from: "B")
        client.draft = "next"
        client.sendPrompt()
        links.receive(.queueState(sessionId: "s", items: [
            RemoteQueuedPrompt(id: UUID().uuidString, text: "next", imageCount: 0, resourceCount: 0,
                               status: "pending", lastError: nil, scheduledAt: nil)
        ]), from: "B")
        #expect(client.draft.isEmpty)
        client.draft = "after"
        client.sendPrompt()
        #expect(links.sent(to: "B").contains(.sendPrompt(sessionId: "s", text: "after", attachments: [], intent: "auto")))
    }

    @Test func queueStateWithAnIdenticalOlderItemDoesNotConfirmTheSend() {
        let (links, client) = drivenClient(canDrive: true)
        links.receive(.transcriptDelta(sessionId: "s", streamingState: "streaming", canDrive: true, upserts: [],
                                       epoch: 1, revision: 1), from: "B")
        func item(_ id: UUID) -> RemoteQueuedPrompt {
            RemoteQueuedPrompt(id: id.uuidString, text: "continue", imageCount: 0, resourceCount: 0,
                               status: "pending", lastError: nil, scheduledAt: nil)
        }
        let older = UUID()
        links.receive(.queueState(sessionId: "s", items: [item(older)]), from: "B")
        client.draft = "continue"
        client.sendPrompt()
        links.receive(.queueState(sessionId: "s", items: [item(older)]), from: "B")
        #expect(client.draft == "continue")
        #expect(client.isPromptPending)
        links.receive(.queueState(sessionId: "s", items: [item(older), item(UUID())]), from: "B")
        #expect(client.draft.isEmpty)
        #expect(!client.isPromptPending)
    }

    @Test(arguments: [("", "fix this"), ("unsent", "unsent\nfix this")])
    func queueEditRestoredKeepsAnUnsentDraft(existing: String, expected: String) {
        let (links, client) = drivenClient(canDrive: true)
        client.draft = existing
        links.receive(.queueEditRestored(sessionId: "s", itemId: "i", text: "fix this"), from: "B")
        #expect(client.draft == expected)
    }

    @Test func queueEditRestoredAfterSwitchingSessionsReturnsWithTheSession() {
        let (links, client) = drivenClient(canDrive: true)
        links.receive(.sessionList(sessions: [row("s"), row("t")]), from: "B")
        client.queueEdit("i")
        client.select("B:t")
        links.receive(.queueEditRestored(sessionId: "s", itemId: "i", text: "fix this"), from: "B")
        #expect(client.draft.isEmpty)
        client.select("B:s")
        #expect(client.draft == "fix this")
        client.select("B:t")
        client.select("B:s")
        #expect(client.draft.isEmpty)
    }

    private func queued(canRemove: Bool? = nil, images: Int = 0, resources: Int = 0) -> RemoteQueuedPrompt {
        RemoteQueuedPrompt(id: UUID().uuidString, text: "t", imageCount: images, resourceCount: resources,
                           status: "pending", lastError: nil, scheduledAt: nil, canRemove: canRemove)
    }

    @Test(arguments: [
        (true, 0, 0, true), (nil, 0, 0, true), (false, 0, 0, false), (true, 1, 0, false), (true, 0, 2, false),
    ] as [(Bool?, Int, Int, Bool)])
    func queuedItemIsEditableOnlyWhenRemovableAndAttachmentFree(
        canRemove: Bool?, images: Int, resources: Int, expected: Bool
    ) {
        let item = queued(canRemove: canRemove, images: images, resources: resources)
        #expect(NativePeerComposerState.canEdit(item) == expected)
    }

    @Test func clearIsOfferedOnlyWhenSomeQueuedItemIsRemovable() {
        #expect(!NativePeerComposerState.canClear([queued(canRemove: false), queued(canRemove: false)]))
        #expect(NativePeerComposerState.canClear([queued(canRemove: false), queued(canRemove: nil)]))
    }

    /// The smallest bytes that sniff as a PNG.
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @Test(arguments: ["look at this", ""])
    func attachedImagesRideThePromptAndClearOnceTheHostEchoesThem(text: String) {
        let (links, client) = drivenClient(canDrive: true)
        client.draft = text
        #expect(client.addAttachment(png, name: "shot.png") == nil)
        client.sendPrompt()
        let wire = RemoteAttachment(name: "shot.png", mimeType: "image/png", dataBase64: png.base64EncodedString())
        #expect(links.sent(to: "B").contains(.sendPrompt(sessionId: "s", text: text, attachments: [wire], intent: "auto")))
        #expect(client.attachments.count == 1)

        // The host labels each image on the user row it records.
        let rowText = text.isEmpty ? "🖼 shot.png" : text + "\n\n🖼 shot.png"
        links.receive(.transcriptDelta(sessionId: "s", streamingState: "streaming", canDrive: true, upserts: [
            .init(stableId: "m0", kind: "user", text: rowText, json: nil, index: 0),
        ], epoch: 1, revision: 1), from: "B")
        #expect(!client.isPromptPending)
        #expect(client.draft.isEmpty)
        #expect(client.attachments.isEmpty)
    }

    @Test func attachmentsTheHostWouldRefuseAreNeverStaged() {
        let (_, client) = drivenClient(canDrive: true)
        #expect(client.addAttachment(Data("not an image".utf8), name: "notes.txt") != nil)
        for _ in 0..<RemoteSessionGateway.maxAttachmentCount { client.addAttachment(png, name: nil) }
        #expect(client.addAttachment(png, name: nil) != nil)
        #expect(client.attachments.count == RemoteSessionGateway.maxAttachmentCount)
    }

    @Test(arguments: [
        (1, [], true), (10_000_000, [], true), (10_000_001, [], false), (1, [9_999_999], true),
        (2, [9_999_999], false), (1, Array(repeating: 1, count: 10), false),
    ] as [(Int, [Int], Bool)])
    func fileSizeIsJudgedAgainstTheRemainingBatchBudgetBeforeReading(size: Int, staged: [Int], fits: Bool) {
        #expect((NativePeerComposerState.attachmentSizeRefusal(size, stagedSizes: staged) == nil) == fits)
    }

    @Test(arguments: [
        ("/re", 0, 3, "/review ", 8),
        ("please /re now", 7, 10, "please /review  now", 15),
        ("🙂 /", 3, 4, "🙂 /review ", 11),
    ])
    func pickingASlashCommandReplacesTheTypedToken(
        text: String, start: Int, caret: Int, expected: String, expectedCaret: Int
    ) {
        let completed = NativePeerComposerState.completingToken(
            "/review", in: text, tokenStart: start, caret: caret)
        #expect(completed.text == expected)
        #expect(completed.caret == expectedCaret)
    }

    @Test(arguments: [
        ("@", 1, 0, ""), ("see @Alas/Sources/App.swift", 27, 4, "Alas/Sources/App.swift"),
        ("@App.swift#run", 14, 0, "App.swift#run"), ("mail a@b", 8, nil, nil), ("@done next", 10, nil, nil),
        ("x\n@a", 4, 2, "a"),
    ] as [(String, Int, Int?, String?)])
    func mentionTokenIsTheAtWordAtTheCaret(text: String, caret: Int, start: Int?, query: String?) {
        let token = NativePeerComposerState.activeMentionToken(in: text as NSString, caret: caret)
        #expect(token?.start == start)
        #expect(token?.query == query)
    }

    @Test func promptsCarryOnlyTheMentionsStillInTheDraftAndDropStaleCandidates() {
        let (links, client) = drivenClient(canDrive: true)
        var config = RemoteSessionConfig(sessionId: "s", models: [], modes: [], currentModel: nil, currentMode: nil,
                                         autoRunEnabled: false, acceptsImages: false)
        config.supportsMentions = true
        links.receive(.sessionConfig(config), from: "B")
        let file = RemoteMention(kind: RemoteMention.file, value: "App.swift", name: "App.swift")
        let session = RemoteMention(kind: RemoteMention.session, value: "s2", name: "Refactor")

        client.searchMentions("ap")
        client.searchMentions("app")
        #expect(links.sent(to: "B").contains(.searchMentions(sessionId: "s", query: "app")))
        links.receive(.mentionCandidates(sessionId: "s", query: "ap", candidates: [session]), from: "B")
        #expect(client.mentionCandidates.isEmpty)
        #expect(client.mentionCandidatesQuery == nil)
        links.receive(.mentionCandidates(sessionId: "s", query: "app", candidates: [file]), from: "B")
        #expect(client.mentionCandidates == [file])
        #expect(client.mentionCandidatesQuery == "app")

        // Past the host's cap a pick is refused up front.
        let many = (0..<RemoteSessionGateway.maxMentionCount).map {
            RemoteMention(kind: RemoteMention.file, value: "f\($0)", name: "f\($0)")
        }
        client.draft = many.map { "@" + $0.name }.joined(separator: " ")
        #expect(many.allSatisfy { client.addMention($0) == nil })
        #expect(client.addMention(file) == NativePeerComposerState.tooManyMentions)

        // Picks land in the draft as they're made; the session's marker is then deleted.
        client.draft = "fix @App.swift"
        client.addMention(file)
        client.draft = "fix @App.swift @Refactor"
        client.addMention(session)
        client.draft = "fix @App.swift"
        client.sendPrompt()
        #expect(links.sent(to: "B").last == .sendPrompt(
            sessionId: "s", text: "fix @App.swift", attachments: [], intent: "auto", mentions: [file]))
    }

    @Test(arguments: [
        // No span: the update replaces the selection.
        ("fix  bug", nil, NSRange(location: 4, length: 0), "the", false, "fix the bug", NSRange(location: 4, length: 3), 7),
        ("fix old bug", nil, NSRange(location: 4, length: 3), "the", true, "fix the bug", nil, 7),
        // A volatile correction replaces the open span, wherever the caret is.
        ("fix teh bug", NSRange(location: 4, length: 3), NSRange(location: 0, length: 0), "the", false,
         "fix the bug", NSRange(location: 4, length: 3), 7),
        // A final update commits the span; the next one starts after it.
        ("🙂 hel", NSRange(location: 3, length: 3), NSRange(location: 6, length: 0), "hello", true, "🙂 hello", nil, 8),
        // A span the draft no longer covers is clamped, not trapped on.
        ("ab", NSRange(location: 1, length: 9), NSRange(location: 2, length: 0), "c", false, "ac", NSRange(location: 1, length: 1), 2),
    ] as [(String, NSRange?, NSRange, String, Bool, String, NSRange?, Int)])
    func dictationReplacesItsSpanOrTheSelection(
        text: String, span: NSRange?, selection: NSRange, transcript: String, isFinal: Bool,
        expected: String, expectedSpan: NSRange?, expectedCaret: Int
    ) {
        let edit = NativePeerComposerState.applyingDictation(
            transcript, isFinal: isFinal, to: text, span: span, selection: selection)
        #expect(edit == .init(text: expected, span: expectedSpan, caret: expectedCaret))
    }

    @Test func queueRowsMoveByTheLocalRulesAndRouteMoveAndPromote() {
        func item(_ id: UUID, status: String = "pending", scheduled: Bool = false) -> RemoteQueuedPrompt {
            RemoteQueuedPrompt(id: id.uuidString, text: "t", imageCount: 0, resourceCount: 0, status: status,
                               lastError: nil, scheduledAt: scheduled ? 1_800_000_000_000 : nil)
        }
        let (head, a, b, later) = (UUID(), UUID(), UUID(), UUID())
        let targets = NativePeerComposerState.moveTargets([
            item(head, status: "sending"), item(a), item(b), item(later, scheduled: true),
        ])
        // Nothing passes the in-flight head; scheduled items neither move nor get passed.
        #expect(targets[a.uuidString] == .init(up: nil, down: b.uuidString))
        #expect(targets[b.uuidString] == .init(up: a.uuidString, down: nil))
        #expect(targets[later.uuidString] == .init(up: nil, down: nil))
        #expect(targets[head.uuidString] == nil)

        let (links, client) = drivenClient(canDrive: true)
        client.queueMove(b.uuidString, to: a.uuidString)
        client.queuePromote(b.uuidString)
        #expect(links.sent(to: "B").suffix(2) == [
            .queueMove(sessionId: "s", itemId: b.uuidString, targetItemId: a.uuidString),
            .queuePromote(sessionId: "s", itemId: b.uuidString),
        ])
    }

    @Test(arguments: [
        ("hello", 0, 0, "hello"),
        ("", 2, 0, "🖼 ×2"),
        ("", 0, 1, "📎 ×1"),
        ("see", 1, 3, "see\n🖼 ×1 📎 ×3"),
    ])
    func queuedItemsWithAttachmentsShowCountMarkers(text: String, images: Int, resources: Int, expected: String) {
        let item = RemoteQueuedPrompt(id: UUID().uuidString, text: text, imageCount: images,
                                      resourceCount: resources, status: "pending", lastError: nil, scheduledAt: nil)
        #expect(NativePeerComposerState.displayText(for: item) == expected)
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
            if case .sendPrompt(_, "run the checks", _, _, _) = $0 { return true }
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
