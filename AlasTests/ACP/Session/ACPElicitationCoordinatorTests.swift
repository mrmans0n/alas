import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP elicitation coordinator")
struct ACPElicitationCoordinatorTests {
    @Test("request-scoped form is available before a remote session id")
    func requestScopedForm() async throws {
        let (coordinator, session, client) = makeCoordinator()
        coordinator.start()
        let params = try decodeParams(#"""
        {
          "requestId": 1,
          "mode": "form",
          "message": "Choose a strategy",
          "requestedSchema": {
            "type": "object",
            "properties": {
              "strategy": {
                "type": "string",
                "oneOf": [
                  {"const":"safe","title":"Safe"},
                  {"const":"fast","title":"Fast"}
                ]
              }
            },
            "required": ["strategy"]
          }
        }
        """#)

        client.emitElicitation(id: .number(40), params: params)
        try await waitUntil { !session.transcript.pendingUserInputs.isEmpty }
        let request = try #require(session.transcript.pendingUserInputs.first)
        #expect(request.fields.map(\.key) == ["strategy"])
        #expect(session.transcript.streamingState == .awaitingInput)

        coordinator.respond(to: request.id, action: .submit(["strategy": .string("safe")]))
        try await waitUntil { client.elicitationResponses[.number(40)] != nil }
        guard case .success(let response) = client.elicitationResponses[.number(40)] else {
            Issue.record("expected success response")
            return
        }
        #expect(response == .accept(["strategy": .string("safe")]))
        #expect(session.transcript.pendingUserInputs.isEmpty)
        #expect(session.transcript.streamingState == .idle)
    }

    @Test("request-scoped elicitation can unblock initialize")
    func elicitationDuringInitialize() async throws {
        let (coordinator, session, client) = makeCoordinator()
        coordinator.start()
        let params = try decodeParams(#"""
        {"requestId":1,"mode":"form","message":"Workspace", "requestedSchema":{
          "properties":{"name":{"type":"string"}},"required":["name"]
        }}
        """#)
        client.scriptAsync(method: "initialize") { _ in
            client.emitElicitation(id: .number(11), params: params)
            while client.elicitationResponses[.number(11)] == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            return Data(#"{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}"#.utf8)
        }
        let connection = ACPConnection(client: client)
        let initialize = Task { try await connection.initialize() }

        try await waitUntil { !session.transcript.pendingUserInputs.isEmpty }
        let request = try #require(session.transcript.pendingUserInputs.first)
        coordinator.respond(to: request.id, action: .submit(["name": .string("Alas")]))

        _ = try await initialize.value
        #expect(session.transcript.pendingUserInputs.isEmpty)
    }

    @Test("Cursor questions use the shared queue without changing streaming state")
    func cursorAdapter() async throws {
        let (coordinator, session, client) = makeCoordinator()
        coordinator.start()
        session.transcript.streamingState = .streaming
        let params = ACPQuestionRequestParams(
            toolCallId: "call",
            title: "Need input",
            questions: [
                .init(
                    id: "q1",
                    prompt: "Pick one",
                    options: [.init(id: "a", label: "A")],
                    allowMultiple: false
                )
            ]
        )

        client.emitQuestion(id: .number(2), params: params)
        try await waitUntil { !session.transcript.pendingUserInputs.isEmpty }
        let request = try #require(session.transcript.pendingUserInputs.first)
        #expect(session.transcript.streamingState == .streaming)

        coordinator.respond(to: request.id, action: .submit(["q1": .string("a")]))
        try await waitUntil { client.questionResponses[.number(2)] != nil }
        #expect(client.questionResponses[.number(2)] == .init(outcome: .answered(answers: [
            .init(questionId: "q1", selectedOptionIds: ["a"])
        ])))
    }

    @Test("Cursor responses resolve the matching queued request")
    func cursorResponseIdentity() async throws {
        let (coordinator, session, client) = makeCoordinator()
        coordinator.start()
        let first = ACPQuestionRequestParams.stub(title: "First")
        let second = ACPQuestionRequestParams.stub(title: "Second")
        client.emitQuestion(id: .number(1), params: first)
        client.emitQuestion(id: .number(2), params: second)
        try await waitUntil { session.transcript.pendingUserInputs.count == 2 }

        coordinator.respondToCursor(
            id: .number(2),
            response: .init(outcome: .answered(answers: [
                .init(questionId: "q1", selectedOptionIds: ["o1"])
            ]))
        )

        try await waitUntil { client.questionResponses[.number(2)] != nil }
        #expect(client.questionResponses[.number(1)] == nil)
        #expect(session.transcript.pendingUserInputs.count == 1)
        #expect(session.transcript.pendingQuestion?.id == .number(1))
    }

    @Test("awaiting input callback fires once per request id")
    func awaitingInputCallbackFiresOncePerRequestId() async throws {
        var notifications: [(ACPSession, ACPUserInputRequest)] = []
        let (coordinator, session, client) = makeCoordinator(onInputAwaiting: { session, request in
            notifications.append((session, request))
        })
        coordinator.start()
        let params = ACPQuestionRequestParams.stub(title: "Need input")

        client.emitQuestion(id: .number(42), params: params)
        try await waitUntil {
            notifications.count == 1 && session.transcript.pendingUserInputs.count == 1
        }

        client.emitQuestion(id: .number(42), params: params)
        try await waitUntil { session.transcript.pendingUserInputs.count == 2 }

        #expect(notifications.count == 1)
        #expect(notifications[0].0.id == "local")
        #expect(notifications[0].1.source == .cursor(id: .number(42), params: params))
    }

    @Test("awaiting input callback fires again when a resolved request id is reused")
    func awaitingInputCallbackFiresAgainForReusedResolvedRequestId() async throws {
        var notifications: [(ACPSession, ACPUserInputRequest)] = []
        let (coordinator, session, client) = makeCoordinator(onInputAwaiting: { session, request in
            notifications.append((session, request))
        })
        coordinator.start()
        let params = ACPQuestionRequestParams.stub(title: "Need input")

        client.emitQuestion(id: .number(42), params: params)
        try await waitUntil {
            notifications.count == 1 && session.transcript.pendingUserInputs.count == 1
        }
        let request = try #require(session.transcript.pendingUserInputs.first)

        coordinator.respond(to: request.id, action: .submit(["q1": .string("o1")]))
        try await waitUntil { session.transcript.pendingUserInputs.isEmpty }

        client.emitQuestion(id: .number(42), params: params)

        try await waitUntil { notifications.count == 2 }
        #expect(session.transcript.pendingUserInputs.count == 1)
        #expect(notifications.map { $0.1.source } == [
            .cursor(id: .number(42), params: params),
            .cursor(id: .number(42), params: params)
        ])
    }

    @Test("awaiting input callback fires again when a cancelled request id is reused")
    func awaitingInputCallbackFiresAgainForReusedCancelledRequestId() async throws {
        var notifications: [(ACPSession, ACPUserInputRequest)] = []
        let (coordinator, session, client) = makeCoordinator(onInputAwaiting: { session, request in
            notifications.append((session, request))
        })
        coordinator.start()
        let params = ACPQuestionRequestParams.stub(title: "Need input")

        client.emitQuestion(id: .number(42), params: params)
        try await waitUntil {
            notifications.count == 1 && session.transcript.pendingUserInputs.count == 1
        }

        coordinator.cancelPendingInputs()
        #expect(session.transcript.pendingUserInputs.isEmpty)

        client.emitQuestion(id: .number(42), params: params)

        try await waitUntil { notifications.count == 2 }
        #expect(session.transcript.pendingUserInputs.count == 1)
        #expect(notifications.map { $0.1.source } == [
            .cursor(id: .number(42), params: params),
            .cursor(id: .number(42), params: params)
        ])
    }

    @Test("standard elicitation notifies awaiting input")
    func standardElicitationNotifiesAwaitingInput() async throws {
        var notifications: [(ACPSession, ACPUserInputRequest)] = []
        let (coordinator, session, client) = makeCoordinator(onInputAwaiting: { session, request in
            notifications.append((session, request))
        })
        coordinator.start()
        let params = try decodeParams(#"""
        {"requestId":1,"mode":"form","message":"Name","requestedSchema":{"properties":{}}}
        """#)

        client.emitElicitation(id: .string("elicitation-1"), params: params)

        try await waitUntil { notifications.count == 1 }
        #expect(notifications[0].0.id == session.id)
        #expect(notifications[0].1.message == "Name")
    }

    @Test("URL mode opens explicitly and waits for completion")
    func urlMode() async throws {
        var opened: URL?
        var clientForNavigation: ACPMockClient?
        var responseWasSentBeforeOpen = false
        let (coordinator, session, client) = makeCoordinator(navigateURL: {
            responseWasSentBeforeOpen = clientForNavigation?.elicitationResponses[.number(9)] != nil
            opened = $0
        })
        clientForNavigation = client
        coordinator.start()
        let params = try decodeParams(#"""
        {
          "requestId": "auth",
          "mode": "url",
          "message": "Sign in",
          "elicitationId": "auth-1",
          "url": "https://example.com/connect"
        }
        """#)
        client.emitElicitation(id: .number(9), params: params)
        try await waitUntil { !session.transcript.pendingUserInputs.isEmpty }
        let request = try #require(session.transcript.pendingUserInputs.first)

        #expect(await coordinator.openURL(for: request.id))
        #expect(opened?.absoluteString == "https://example.com/connect")
        #expect(responseWasSentBeforeOpen)
        guard case .success(let response) = client.elicitationResponses[.number(9)] else {
            Issue.record("expected URL acceptance")
            return
        }
        #expect(response == .accept())
        #expect(response.content == nil)
        #expect(session.transcript.urlElicitationWaits.map(\.id) == ["auth-1"])
        client.emitElicitationComplete(elicitationId: "auth-1")
        try await waitUntil { session.transcript.urlElicitationWaits.isEmpty }
    }

    @Test("URL mode stays pending when no browser can open the URL")
    func urlModeOpenFailure() async throws {
        var didNavigate = false
        let (coordinator, session, client) = makeCoordinator(
            launchBrowser: { _ in false },
            navigateURL: { _ in
                didNavigate = true
            }
        )
        coordinator.start()
        let params = try decodeParams(#"""
        {
          "requestId": "auth",
          "mode": "url",
          "message": "Sign in",
          "elicitationId": "auth-1",
          "url": "https://example.com/connect"
        }
        """#)
        client.emitElicitation(id: .number(10), params: params)
        try await waitUntil { !session.transcript.pendingUserInputs.isEmpty }
        let request = try #require(session.transcript.pendingUserInputs.first)

        #expect(!(await coordinator.openURL(for: request.id)))
        #expect(!didNavigate)
        #expect(client.elicitationResponses[.number(10)] == nil)
        #expect(session.transcript.pendingUserInputs.map(\.id) == [request.id])
        #expect(session.transcript.urlElicitationWaits.isEmpty)
    }

    @Test("invalid mode returns invalid params")
    func invalidMode() async throws {
        let (coordinator, _, client) = makeCoordinator()
        coordinator.start()
        let params = try decodeParams(#"""
        {"requestId":1,"mode":"binary","message":"Upload"}
        """#)
        client.emitElicitation(id: .number(7), params: params)
        try await waitUntil { client.elicitationResponses[.number(7)] != nil }
        guard case .failure(let error) = client.elicitationResponses[.number(7)] else {
            Issue.record("expected invalid params")
            return
        }
        #expect(error.code == -32602)
    }

    @Test("stop cancels every unresolved request exactly once")
    func stopCancelsPending() async throws {
        let (coordinator, session, client) = makeCoordinator()
        coordinator.start()
        let params = try decodeParams(#"""
        {"requestId":1,"mode":"form","message":"Name","requestedSchema":{"properties":{}}}
        """#)
        client.emitElicitation(id: .number(3), params: params)
        try await waitUntil { !session.transcript.pendingUserInputs.isEmpty }
        coordinator.stop()
        guard case .success(let response) = client.elicitationResponses[.number(3)] else {
            Issue.record("expected cancellation")
            return
        }
        #expect(response == .cancel)
        #expect(session.transcript.pendingUserInputs.isEmpty)
    }

    @Test("resolving input notifies the queue owner")
    func resolutionNotifiesQueueOwner() async throws {
        var resolutionCount = 0
        let (coordinator, session, client) = makeCoordinator(onInputResolved: {
            resolutionCount += 1
        })
        coordinator.start()
        let params = try decodeParams(#"""
        {"requestId":1,"mode":"form","message":"Name","requestedSchema":{"properties":{}}}
        """#)
        client.emitElicitation(id: .number(3), params: params)
        try await waitUntil { !session.transcript.pendingUserInputs.isEmpty }
        let request = try #require(session.transcript.pendingUserInputs.first)

        coordinator.respond(to: request.id, action: .submit([:]))

        #expect(resolutionCount == 1)
    }

    private func makeCoordinator(
        onInputAwaiting: @escaping (ACPSession, ACPUserInputRequest) -> Void = { _, _ in },
        onInputResolved: @escaping () -> Void = {},
        launchBrowser: @escaping (URL) async -> Bool = { _ in true },
        navigateURL: @escaping (URL) -> Void = { _ in }
    ) -> (ACPElicitationCoordinator, ACPSession, ACPMockClient) {
        let session = ACPSession(id: "local", agentId: "codex", worktreeId: "wt", title: "Test")
        let client = ACPMockClient()
        return (
            ACPElicitationCoordinator(
                session: session,
                client: client,
                launchBrowser: launchBrowser,
                navigateURL: navigateURL,
                onInputAwaiting: onInputAwaiting,
                onInputResolved: onInputResolved
            ),
            session,
            client
        )
    }

    private func decodeParams(_ json: String) throws -> ACPElicitationRequestParams {
        try JSONDecoder().decode(ACPElicitationRequestParams.self, from: Data(json.utf8))
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !predicate() {
            if ContinuousClock.now - start > timeout {
                Issue.record("timed out waiting for predicate")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
