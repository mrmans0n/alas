import Foundation
import Testing
@testable import Alas

@Suite("ACPStdioClient question dispatch")
struct ACPStdioQuestionDispatchTests {
    @Test("cursor/ask_question incoming frame yields question request")
    func dispatchesCursorAskQuestion() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()

        let json = #"""
        {"jsonrpc":"2.0","id":42,"method":"cursor/ask_question","params":{
          "toolCallId":"call_123",
          "title":"Need input",
          "questions":[{
            "id":"q1",
            "prompt":"Which implementation path should I take?",
            "options":[
              {"id":"cursor","label":"Implement Cursor first"},
              {"id":"generic","label":"Wait for generic ACP"}
            ],
            "allowMultiple":false
          }]
        }}
        """#

        transport.send(frame: Data(json.utf8))

        var it = client.questionRequests.makeAsyncIterator()
        let req = await it.next()
        #expect(req?.id == .number(42))
        #expect(req?.params.toolCallId == "call_123")
        #expect(req?.params.title == "Need input")
        #expect(req?.params.questions.first?.prompt == "Which implementation path should I take?")
        #expect(req?.params.questions.first?.options.map(\.id) == ["cursor", "generic"])
        #expect(req?.params.questions.first?.allowMultiple == false)
    }

    @Test("respondToQuestion sends Cursor-compatible JSON-RPC result")
    func sendsAnsweredQuestionResponse() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()

        let response = ACPQuestionResponse(
            outcome: .answered(answers: [
                .init(questionId: "q1", selectedOptionIds: ["cursor"])
            ])
        )

        client.respondToQuestion(id: .number(42), response: response)

        try await waitUntil {
            !transport.sentFrames.isEmpty
        }

        let object = try #require(
            JSONSerialization.jsonObject(with: transport.sentFrames[0]) as? [String: Any]
        )
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 42)
        let result = try #require(object["result"] as? [String: Any])
        let outcome = try #require(result["outcome"] as? [String: Any])
        #expect(outcome["outcome"] as? String == "answered")
        let answers = try #require(outcome["answers"] as? [[String: Any]])
        #expect(answers.first?["questionId"] as? String == "q1")
        #expect(answers.first?["selectedOptionIds"] as? [String] == ["cursor"])
    }

    @Test("elicitation create and completion frames are dispatched")
    func dispatchesElicitationFrames() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()
        transport.send(frame: Data(#"""
        {"jsonrpc":"2.0","id":8,"method":"elicitation/create","params":{
          "requestId":1,"mode":"form","message":"Name", "requestedSchema":{
            "type":"object","properties":{"name":{"type":"string"}},"required":["name"]
          }
        }}
        """#.utf8))

        var requests = client.elicitationRequests.makeAsyncIterator()
        let request = await requests.next()
        #expect(request?.id == .number(8))
        #expect(request?.params.requestedSchema?.properties["name"]?.type == "string")

        transport.send(frame: Data(#"""
        {"jsonrpc":"2.0","method":"elicitation/complete","params":{"elicitationId":"auth-1"}}
        """#.utf8))
        var completions = client.elicitationCompletions.makeAsyncIterator()
        #expect(await completions.next() == .init(elicitationId: "auth-1"))
    }

    @Test("elicitation responses use the standardized action shape")
    func sendsElicitationResponse() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()

        client.respondToElicitation(
            id: .number(8),
            result: .success(.accept(["name": .string("Alas")]))
        )
        try await waitUntil { !transport.sentFrames.isEmpty }
        let object = try #require(
            JSONSerialization.jsonObject(with: transport.sentFrames[0]) as? [String: Any]
        )
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["action"] as? String == "accept")
        #expect((result["content"] as? [String: Any])?["name"] as? String == "Alas")
    }

    @Test("unknown inbound request receives method-not-found error")
    func rejectsUnknownInboundRequest() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()

        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":"unknown-1","method":"cursor/future_extension","params":{}}"#.utf8))

        try await waitUntil { !transport.sentFrames.isEmpty }
        let response = try #require(
            JSONSerialization.jsonObject(with: transport.sentFrames[0]) as? [String: Any]
        )
        #expect(response["jsonrpc"] as? String == "2.0")
        #expect(response["id"] as? String == "unknown-1")
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
    }

    @Test("Cursor update, task, and image requests are acknowledged")
    func acknowledgesCursorExtensionRequests() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()

        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"method":"cursor/update_todos","params":{"toolCallId":"todo-call","todos":[{"id":"todo-1","content":"Implement","status":"in_progress"}],"merge":true}}"#.utf8))
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":2,"method":"cursor/task","params":{"toolCallId":"task-call","description":"Explore","prompt":"Inspect the ACP client","agentId":"agent-1","durationMs":42}}"#.utf8))
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":3,"method":"cursor/generate_image","params":{"toolCallId":"image-call","description":"Logo","filePath":"/tmp/logo.png","referenceImagePaths":[]}}"#.utf8))

        try await waitUntil { transport.sentFrames.count == 3 }
        let responses = try transport.sentFrames.map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }

        let todosResponse = try #require(responses.first { $0["id"] as? Int == 1 })
        let todos = try #require(todosResponse["result"] as? [String: Any])
        let todoOutcome = try #require(todos["outcome"] as? [String: Any])
        #expect(todoOutcome["outcome"] as? String == "accepted")
        #expect((todoOutcome["todos"] as? [[String: Any]])?.first?["id"] as? String == "todo-1")

        let taskResponse = try #require(responses.first { $0["id"] as? Int == 2 })
        let task = try #require(taskResponse["result"] as? [String: Any])
        let taskOutcome = try #require(task["outcome"] as? [String: Any])
        #expect(taskOutcome["outcome"] as? String == "completed")
        #expect(taskOutcome["agentId"] as? String == "agent-1")
        #expect(taskOutcome["durationMs"] as? Int == 42)

        let imageResponse = try #require(responses.first { $0["id"] as? Int == 3 })
        let image = try #require(imageResponse["result"] as? [String: Any])
        let imageOutcome = try #require(image["outcome"] as? [String: Any])
        #expect(imageOutcome["outcome"] as? String == "generated")
        #expect(imageOutcome["filePath"] as? String == "/tmp/logo.png")
        #expect(imageOutcome["imageData"] as? String == "")
    }

    @Test("Cursor create plan is dispatched and responds with the selected outcome")
    func dispatchesCursorCreatePlan() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()

        transport.send(frame: Data(##"{"jsonrpc":"2.0","id":"plan-1","method":"cursor/create_plan","params":{"toolCallId":"plan-call","name":"Fix ACP","overview":"Keep requests moving","plan":"# Plan\n\nImplement the replies.","todos":[{"id":"todo-1","content":"Implement","status":"pending"}],"isProject":false,"phases":[{"name":"Implementation","todos":[{"id":"todo-1","content":"Implement","status":"pending"}]}]}}"##.utf8))

        var iterator = client.planRequests.makeAsyncIterator()
        let request = try #require(await iterator.next())
        #expect(request.id == .string("plan-1"))
        #expect(request.params.name == "Fix ACP")
        #expect(request.params.plan == "# Plan\n\nImplement the replies.")
        #expect(request.params.todos.map(\.content) == ["Implement"])

        client.respondToPlan(
            id: request.id,
            response: .init(outcome: .accepted(planUri: "alas://plans/plan-call"))
        )
        try await waitUntil { !transport.sentFrames.isEmpty }
        let response = try #require(
            JSONSerialization.jsonObject(with: transport.sentFrames[0]) as? [String: Any]
        )
        let outcome = try #require((response["result"] as? [String: Any])?["outcome"] as? [String: Any])
        #expect(outcome["outcome"] as? String == "accepted")
        #expect(outcome["planUri"] as? String == "alas://plans/plan-call")
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @Sendable () -> Bool
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
