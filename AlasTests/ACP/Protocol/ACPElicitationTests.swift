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

    private func decode(_ json: String) throws -> ACPElicitationRequestParams {
        try JSONDecoder().decode(ACPElicitationRequestParams.self, from: Data(json.utf8))
    }
}
