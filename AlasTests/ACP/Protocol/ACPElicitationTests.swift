import Foundation
import Testing
@testable import Alas

@Suite("ACP elicitation wire models")
struct ACPElicitationTests {
    @Test("decodes every supported form property shape")
    func decodesFormProperties() throws {
        let params = try JSONDecoder().decode(
            ACPElicitationRequestParams.self,
            from: Data(#"""
            {
              "sessionId":"s1","toolCallId":"tc1","mode":"form","message":"Configure",
              "requestedSchema":{"type":"object","properties":{
                "text":{"type":"string","minLength":1,"format":"email","default":"a@example.com"},
                "ratio":{"type":"number","minimum":0,"maximum":1,"default":0.5},
                "count":{"type":"integer","minimum":1,"default":2},
                "enabled":{"type":"boolean","default":true},
                "choice":{"type":"string","oneOf":[{"const":"a","title":"A"}]},
                "many":{"type":"array","minItems":1,"items":{"anyOf":[{"const":"x","title":"X"}]}}
              },"required":["text","count"]}
            }
            """#.utf8)
        )
        let fields = try #require(params.requestedSchema?.properties)
        #expect(fields["text"]?.type == "string")
        #expect(fields["ratio"]?.minimum == 0)
        #expect(fields["count"]?.type == "integer")
        #expect(fields["enabled"]?.defaultValue == AnyCodable(true))
        #expect(fields["choice"]?.oneOf?.first?.const == "a")
        #expect(fields["many"]?.items?.anyOf?.first?.const == "x")
    }

    @Test("decodes URL mode and both scope variants")
    func decodesURLAndScopes() throws {
        let requestScoped = try decode(#"""
        {"requestId":"setup","mode":"url","message":"Sign in","elicitationId":"auth","url":"https://example.com/connect"}
        """#)
        #expect(requestScoped.hasExactlyOneScope)
        #expect(requestScoped.requestId == .string("setup"))
        #expect(requestScoped.elicitationId == "auth")

        let invalid = try decode(#"""
        {"requestId":1,"sessionId":"s1","mode":"form","message":"Both","requestedSchema":{"properties":{}}}
        """#)
        #expect(!invalid.hasExactlyOneScope)
    }

    @Test("omitted mode defaults to form")
    func omittedModeDefaultsToForm() throws {
        let params = try decode(#"""
        {"requestId":1,"message":"Configure","requestedSchema":{"properties":{}}}
        """#)

        #expect(params.mode == "form")
        #expect(params.requestedSchema != nil)
    }

    @Test("forms reject missing properties and unknown required keys")
    func invalidFormProperties() throws {
        let missing = try decode(#"""
        {"requestId":1,"message":"Configure","requestedSchema":{"required":["name"]}}
        """#)
        let unknownRequired = try decode(#"""
        {"requestId":2,"message":"Configure","requestedSchema":{"properties":{},"required":["name"]}}
        """#)

        #expect(ACPUserInputRequest.elicitation(.init(id: .number(1), params: missing)) == nil)
        #expect(ACPUserInputRequest.elicitation(.init(id: .number(2), params: unknownRequired)) == nil)
    }

    @Test("content values round trip without wrapper objects")
    func contentValueRoundTrip() throws {
        let response = ACPElicitationResponse.accept([
            "text": .string("hello"),
            "count": .integer(2),
            "ratio": .number(0.5),
            "enabled": .boolean(true),
            "many": .strings(["a", "b"])
        ])
        let data = try JSONEncoder().encode(response)
        #expect(try JSONDecoder().decode(ACPElicitationResponse.self, from: data) == response)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try #require(json["content"] as? [String: Any])
        #expect(content["text"] as? String == "hello")
        #expect(content["count"] as? Int == 2)
        #expect(content["many"] as? [String] == ["a", "b"])
    }

    @Test("URL acceptance omits form content")
    func urlAcceptanceOmitsContent() throws {
        let data = try JSONEncoder().encode(ACPElicitationResponse.accept())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["action"] as? String == "accept")
        #expect(json["content"] == nil)
    }

    @Test("Codex async delivery classifies the form", arguments: [
        (#"{"codex":{"delivery":"async"}}"#, ACPUserInputRequest.Delivery.optional),
        (#"{"codex":{"autoResolutionMs":1}}"#, .blocking),
        ("null", .blocking),
    ])
    func codexAsyncDeliveryClassifiesTheForm(meta: String, expected: ACPUserInputRequest.Delivery) throws {
        let params = try decode(codexAsyncFormJSON(meta: meta))
        let request = try #require(ACPUserInputRequest.elicitation(.init(id: .number(1), params: params)))
        #expect(request.delivery == expected)
        #expect(request.isBlocking == (expected == .blocking))
        #expect(params.isAsyncDelivery == (expected == .optional))
    }

    @Test("an async delivery marker on a URL request stays blocking")
    func asyncURLRequestStaysBlocking() throws {
        let params = try decode(#"""
        {"requestId":"setup","mode":"url","message":"Sign in","elicitationId":"auth","url":"https://example.com/connect","_meta":{"codex":{"delivery":"async"}}}
        """#)
        #expect(!params.isAsyncDelivery)
        let request = try #require(ACPUserInputRequest.elicitation(.init(id: .number(1), params: params)))
        #expect(request.isBlocking)
    }

    private func decode(_ json: String) throws -> ACPElicitationRequestParams {
        try JSONDecoder().decode(ACPElicitationRequestParams.self, from: Data(json.utf8))
    }
}

/// The adapter's `AsyncQuestionClient` payload: a choice question with an own-answer
/// note, then a free-text question, with no `required` list.
func codexAsyncFormJSON(meta: String, noteId: String = "question_0_note", extraProperties: String = "") -> String {
    #"""
    {
      "sessionId":"s1","mode":"form",
      "message":"Codex keeps working while you answer. An answer sent after it finishes is not delivered.",
      "requestedSchema":{"type":"object","properties":{
        "question_0":{"title":"Q0","description":"","_meta":{"codex":{"isOther":true,"isSecret":false}},
          "type":"string","oneOf":[
            {"const":"Staging","title":"Staging"},
            {"const":"Prod","title":"Prod"},
            {"const":"None of the above","title":"None of the above","description":"Provide a different answer in the note field."}]},
        "\#(noteId)":{"type":"string","title":"Additional answer or note",
          "_meta":{"codex":{"questionId":"question_0","role":"user_note","isSecret":false}}},
        "question_1":{"title":"Q1","_meta":{"codex":{"isOther":false,"isSecret":false}},"type":"string"}\#(extraProperties)
      }},
      "_meta":\#(meta)
    }
    """#
}
