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
