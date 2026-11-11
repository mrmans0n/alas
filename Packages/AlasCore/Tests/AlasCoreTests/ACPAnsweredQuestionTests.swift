import Foundation
import Testing
import AlasCore

struct ACPAnsweredQuestionTests {
    private func request() throws -> ACPUserInputRequest {
        let params = try JSONDecoder().decode(ACPElicitationRequestParams.self, from: Data(#"""
        {"mode":"form","message":"Choose the rollout","requestedSchema":{"type":"object","properties":{
          "strategy":{"type":"string","title":"Strategy","description":"How to ship",
            "oneOf":[{"const":"safe","title":"Gradual","description":"Small batches"},{"const":"fast","title":"All at once"}]},
          "note":{"type":"string","title":"Other","_meta":{"questionCustomAnswer":{"version":1,"questionId":"strategy"}}},
          "regions":{"type":"array","title":"Regions","items":{"type":"string","enum":["EU","US"]}},
          "token":{"type":"string","title":"Token","default":"secret-default","_meta":{"codex":{"isSecret":true}}}
        }}}
        """#.utf8))
        return try #require(ACPUserInputRequest.elicitation(.init(id: .number(1), params: params)))
    }

    @Test func answersUseLabelsAndPreserveCustomTextWithoutSecrets() throws {
        let answer = ACPAnsweredQuestion(request: try request(), action: .submit([
            "strategy": .string("safe"), "note": .string("Only after review"),
            "regions": .strings(["US", "EU"]), "token": .string("secret-answer")
        ]))
        #expect(answer.items.map(\.question) == ["Regions", "Strategy", "Token"])
        #expect(answer.items.map(\.answer) == ["US, EU", "Gradual\n\nOnly after review", "Hidden"])
        let strategy = try #require(answer.items.first { $0.question == "Strategy" })
        #expect(strategy.options.map(\.title) == ["Gradual", "All at once"])
        #expect(strategy.options.first?.description == "Small batches")
        let encoded = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        #expect(!encoded.contains("secret-answer"))
        #expect(!encoded.contains("secret-default"))
    }

    @Test(arguments: [(ACPUserInputAction.decline, "Skipped"), (.cancel, "Cancelled")])
    func dismissalsKeepTheQuestion(action: ACPUserInputAction, status: String) throws {
        let answer = ACPAnsweredQuestion(request: try request(), action: action)
        #expect(answer.statusLabel == status)
        #expect(answer.message == "Choose the rollout")
        #expect(answer.items.allSatisfy { $0.answer == nil })
    }

    @MainActor
    @Test func answeredCardSurvivesBothPersistenceDecoders() throws {
        let answer = ACPAnsweredQuestion(request: try request(), action: .submit(["strategy": .string("safe")]))
        let message = ACPMessage.questionAnswer(answer)
        let payload = try ACPMessageCodec.encode(message)
        #expect(try ACPMessageCodec.decode(kind: message.kind, payload: payload) == message)
        let wire = try ACPMessageWire.decode(kind: message.kind, payload: payload)
        #expect(wire.toMessage() == message)
        #expect(wire.toMessage(preservingIdentityFrom: message).stableId == message.stableId)
        #expect(ACPSessionTranscriptReader.entries([message]).first?.text.contains("Gradual") == true)
    }
}
