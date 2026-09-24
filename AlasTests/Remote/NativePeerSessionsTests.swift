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
        options: [RemoteElicitationOption] = [],
        defaultValue: ACPElicitationValue? = nil
    ) -> RemoteElicitationField {
        .init(key: key, type: type, title: key, description: nil, required: required,
              minLength: minLength, maxLength: maxLength, minimum: minimum, maximum: maximum,
              minItems: minItems, maxItems: maxItems, format: format, pattern: pattern,
              options: options, defaultValue: defaultValue)
    }

    @Test func permissionPresentationKeepsToolNameAlongsideTitle() {
        let request = RemotePermissionPayload(
            requestId: 1, toolName: "bash", options: [], title: "Run command?",
            mcpServerName: "build-tools", commandSummary: "swift build"
        )

        let presentation = NativePeerPermissionPresentation(request: request)

        #expect(presentation.title == "Run command?")
        #expect(presentation.toolName == "bash")
        #expect(presentation.commandSummary == "swift build")
        #expect(presentation.mcpServerName == "build-tools")
    }

    @Test func permissionDefaultToNoEmphasizesOneTimeRejection() {
        let presentation = NativePeerPermissionPresentation(request: RemotePermissionPayload(
            requestId: 1,
            toolName: "bash",
            options: [],
            defaultToNo: true
        ))
        let rejectOnce = RemotePermissionOption(optionId: "reject", name: "Reject", kind: "reject_once")
        let allowOnce = RemotePermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")

        #expect(presentation.isDefaultStyled(rejectOnce))
        #expect(presentation.isDefaultAction(rejectOnce))
        #expect(!presentation.isDefaultStyled(allowOnce))
        #expect(!presentation.isDefaultAction(allowOnce))
    }

    @Test func permissionPresentationIncludesOptionDescriptions() {
        let described = RemotePermissionOption(
            optionId: "allow-once", name: "Allow", kind: "allow_once", description: "For this request only."
        )
        let empty = RemotePermissionOption(optionId: "reject", name: "Reject", kind: "reject_once", description: "")
        let presentation = NativePeerPermissionPresentation(request: RemotePermissionPayload(
            requestId: 1, toolName: "bash", options: [described, empty]
        ))

        #expect(presentation.description(for: described) == "For this request only.")
        #expect(presentation.description(for: empty) == nil)
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
        links.receive(.sessionList(sessions: [row("s")]), from: "B")
        let subscriptionsAfter = links.sent(to: "B").filter { $0 == .subscribe(sessionId: "s") }.count
        #expect(subscriptionsAfter == subscriptionsBefore + 1)
        links.receive(.transcriptSnapshot(sessionId: "s", streamingState: "idle", canDrive: true,
                                          messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0), from: "B")
        #expect(client.transcript?.canDrive == true)
        #expect(client.draft == "continue later")
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

    @Test func arrayElicitationSubmitsSelectedOptionsAsStringArray() {
        let field = RemoteElicitationField(
            key: "scopes", type: "array", title: "Scopes", description: nil, required: true,
            minLength: nil, maxLength: nil, minimum: nil, maximum: nil, minItems: 1, maxItems: nil,
            format: nil, pattern: nil,
            options: [
                .init(value: "read", title: "Read", description: nil),
                .init(value: "write", title: "Write", description: nil),
                .init(value: "admin", title: "Admin", description: nil),
            ],
            defaultValue: nil
        )

        let content = NativePeerElicitationForm.submittedContent(
            fields: [field], values: [:], selectedOptions: ["scopes": ["write", "read"]]
        )

        #expect(content == ["scopes": .strings(["read", "write"])])
    }

    @Test func elicitationOptionPresentationIncludesDescriptions() {
        let described = NativePeerElicitationOptionPresentation(option: .init(
            value: "write", title: "Write access", description: "Allows changes to files."
        ))
        let untitled = NativePeerElicitationOptionPresentation(option: .init(
            value: "read", title: nil, description: ""
        ))

        #expect(described.title == "Write access")
        #expect(described.description == "Allows changes to files.")
        #expect(untitled.title == "read")
        #expect(untitled.description == nil)
    }

    @Test func planPreviewIncludesPlanTodosAndPhases() {
        let request = RemotePlanPayload(
            requestId: .string("plan-1"), toolCallId: "tool-1", name: "Implement feature",
            overview: "Add peer visibility.", plan: "Render peer sessions grouped by owner.",
            todos: [.init(id: "todo-1", content: "Update the sidebar", status: "pending")],
            isProject: false,
            phases: [.init(name: "Verification", todos: [
                .init(id: "todo-2", content: "Run native tests", status: "pending"),
            ])]
        )

        let details = NativePeerPlanPresentation.details(for: request)
        #expect(details.contains("Render peer sessions grouped by owner."))
        #expect(details.contains("Todos:\n- [pending] Update the sidebar"))
        #expect(details.contains("Phase: Verification\n- [pending] Run native tests"))
    }

    @Test func stopControlIsShownForEveryActivePeerState() {
        #expect(NativePeerSessionControls.showsStop(for: "streaming"))
        #expect(NativePeerSessionControls.showsStop(for: "awaitingPermission"))
        #expect(NativePeerSessionControls.showsStop(for: "awaitingInput"))
        #expect(!NativePeerSessionControls.showsStop(for: "idle"))
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

    @Test func scalarElicitationRejectsValuesOutsideTheForwardedSchema() {
        let environment = elicitationField("environment", type: "string", options: [
            .init(value: "staging", title: "Staging", description: nil),
            .init(value: "production", title: "Production", description: nil),
        ])
        let port = elicitationField("port", type: "integer", minimum: 1024, maximum: 65535)
        let email = elicitationField("email", type: "string", format: "email")
        let name = elicitationField("name", type: "string", minLength: 3, maxLength: 16, pattern: "^[A-Z].*")
        let fields = [environment, port, email, name]
        let values = ["environment": "production", "port": "3000", "email": "ops@example.com", "name": "Alas"]

        #expect(NativePeerElicitationForm.canSubmit(
            fields: fields, values: values, selectedOptions: ["environment": ["production"]]
        ))

        #expect(!NativePeerElicitationForm.canSubmit(
            fields: fields, values: values, selectedOptions: ["environment": ["unknown"]]
        ))
        #expect(!NativePeerElicitationForm.canSubmit(
            fields: fields,
            values: ["environment": "production", "port": "80", "email": "ops@example.com", "name": "Alas"],
            selectedOptions: ["environment": ["production"]]
        ))
        #expect(!NativePeerElicitationForm.canSubmit(
            fields: fields,
            values: ["environment": "production", "port": "3000", "email": "not-an-email", "name": "Alas"],
            selectedOptions: ["environment": ["production"]]
        ))
        #expect(!NativePeerElicitationForm.canSubmit(
            fields: fields,
            values: ["environment": "production", "port": "3000", "email": "ops@example.com", "name": "ab"],
            selectedOptions: ["environment": ["production"]]
        ))
        #expect(!NativePeerElicitationForm.canSubmit(
            fields: fields,
            values: ["environment": "production", "port": "3000", "email": "ops@example.com", "name": "lowercase"],
            selectedOptions: ["environment": ["production"]]
        ))
    }

    @Test func dateElicitationRejectsImpossibleCalendarDate() {
        let date = elicitationField("date", type: "string", format: "date")

        #expect(!NativePeerElicitationForm.canSubmit(
            fields: [date], values: ["date": "2026-02-31"], selectedOptions: [:]
        ))
        #expect(NativePeerElicitationForm.canSubmit(
            fields: [date], values: ["date": "2026-02-28"], selectedOptions: [:]
        ))
    }

    @Test func scalarElicitationSubmitsSelectedOptionsAndTypedValues() {
        let environment = elicitationField("environment", type: "string", options: [
            .init(value: "staging", title: "Staging", description: nil),
            .init(value: "production", title: "Production", description: nil),
        ])
        let port = elicitationField("port", type: "integer", minimum: 1024, maximum: 65535)
        let enabled = elicitationField("enabled", type: "boolean")

        let content = NativePeerElicitationForm.submittedContent(
            fields: [environment, port, enabled],
            values: ["port": "3000"],
            selectedOptions: ["environment": ["production"]],
            booleanValues: ["enabled": true]
        )

        #expect(content == [
            "environment": .string("production"),
            "port": .integer(3000),
            "enabled": .boolean(true),
        ])
    }

    @Test func booleanElicitationAcceptsEitherExplicitChoice() {
        let enabled = elicitationField("enabled", type: "boolean")

        #expect(!NativePeerElicitationForm.canSubmit(
            fields: [enabled], values: [:], selectedOptions: [:]
        ))
        #expect(NativePeerElicitationForm.canSubmit(
            fields: [enabled], values: [:], selectedOptions: [:], booleanValues: ["enabled": false]
        ))
        #expect(NativePeerElicitationForm.canSubmit(
            fields: [enabled], values: [:], selectedOptions: [:], booleanValues: ["enabled": true]
        ))
    }

    @Test func untouchedOptionalBooleanIsOmittedFromElicitationResponse() {
        let optional = elicitationField("enabled", type: "boolean", required: false)
        let state = NativePeerElicitationForm.State(requestId: "request", fields: [optional])

        let untouched = NativePeerElicitationForm.submittedContent(
            fields: [optional], values: state.values, selectedOptions: state.selectedOptions,
            booleanValues: state.booleanValues
        )
        let explicitlyFalse = NativePeerElicitationForm.submittedContent(
            fields: [optional], values: state.values, selectedOptions: state.selectedOptions,
            booleanValues: ["enabled": false]
        )

        #expect(untouched.isEmpty)
        #expect(explicitlyFalse == ["enabled": .boolean(false)])
    }

    @Test func elicitationFormResetClearsValuesWhenRequestChanges() {
        let originalFields = [
            elicitationField("name", type: "string", defaultValue: .string("old default")),
            elicitationField("scopes", type: "array", required: false),
            elicitationField("enabled", type: "boolean", defaultValue: .boolean(false)),
        ]
        var state = NativePeerElicitationForm.State(requestId: "first", fields: originalFields)
        state.values["name"] = "typed value"
        state.selectedOptions["scopes"] = ["read"]
        state.booleanValues["enabled"] = true

        let nextFields = [
            elicitationField("name", type: "string", defaultValue: .string("new default")),
            elicitationField("scopes", type: "array", required: false),
            elicitationField("enabled", type: "boolean", defaultValue: .boolean(false)),
        ]
        state.reset(requestId: "second", fields: nextFields)

        #expect(state.values["name"] == "new default")
        #expect(state.selectedOptions["scopes"] == nil)
        #expect(state.booleanValues["enabled"] == false)
    }

    @Test func planRejectionReasonResetsForANewRequest() {
        var state = NativePeerPlanRejectionState(requestId: .string("plan-1"))
        state.reason = "Old feedback"

        state.reset(requestId: .string("plan-2"))

        #expect(state.reason.isEmpty)
    }

    @Test func questionSelectionsResetForANewRequest() {
        var state = NativePeerQuestionSelectionState(requestId: 1)
        state.selectedOptions["branch"] = ["main"]

        state.reset(requestId: 2)

        #expect(state.selectedOptions.isEmpty)
    }
}
