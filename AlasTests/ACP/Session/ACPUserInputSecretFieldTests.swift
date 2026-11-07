import Foundation
import Testing
@testable import Alas

@Suite("ACPUserInput Codex field metadata")
struct ACPUserInputSecretFieldTests {
    @Test("a property marked _meta.codex.isSecret renders as a secret field")
    func secretFieldIsDetected() throws {
        let json = """
        {
          "mode": "form",
          "message": "Enter your credentials",
          "requestedSchema": {
            "type": "object",
            "properties": {
              "apiKey": {
                "type": "string",
                "title": "API Key",
                "_meta": { "codex": { "isSecret": true } }
              },
              "username": {
                "type": "string",
                "title": "Username"
              }
            },
            "required": []
          }
        }
        """.data(using: .utf8)!
        let params = try JSONDecoder().decode(ACPElicitationRequestParams.self, from: json)
        let request = ACPElicitationRequest(id: .number(1), params: params)

        let userInput = try #require(ACPUserInputRequest.elicitation(request))

        let apiKey = try #require(userInput.fields.first { $0.key == "apiKey" })
        let username = try #require(userInput.fields.first { $0.key == "username" })
        #expect(apiKey.schema.isSecret == true)
        #expect(username.schema.isSecret == false)
    }

    private func asyncRequest(noteId: String = "question_0_note", extra: String = "") throws -> ACPUserInputRequest {
        let params = try JSONDecoder().decode(
            ACPElicitationRequestParams.self,
            from: Data(codexAsyncFormJSON(
                meta: #"{"codex":{"delivery":"async"}}"#, noteId: noteId, extraProperties: extra
            ).utf8)
        )
        return try #require(ACPUserInputRequest.elicitation(.init(id: .number(1), params: params)))
    }

    @Test("note fields pair with their question by questionId")
    func notesPairByQuestionId() throws {
        let request = try asyncRequest(noteId: "question_0_note1")
        #expect(request.fieldGroups.map(\.field.key) == ["question_0", "question_1"])
        let first = request.fieldGroups[0]
        #expect(first.note?.key == "question_0_note1")
        #expect(first.field.schema.acceptsOwnAnswer)
        #expect(first.field.schema.options.map(\.const).contains(ACPUserInputRequest.ownAnswerOptionConst))
        #expect(request.fieldGroups[1].note == nil)
        #expect(request.fields.first { $0.key == "question_0_note1" }?.schema.noteForQuestion == "question_0")
    }

    private func questionForm(_ properties: String) throws -> ACPUserInputRequest {
        let params = try JSONDecoder().decode(
            ACPElicitationRequestParams.self,
            from: Data(#"{"mode":"form","message":"m","requestedSchema":{"type":"object","properties":{\#(properties)}}}"#.utf8)
        )
        return try #require(ACPUserInputRequest.elicitation(.init(id: .number(1), params: params)))
    }

    private static let select = #"{"type":"string","oneOf":[{"const":"A","title":"Same"},{"const":"B","title":"Same"}]}"#

    private static func other(_ marker: String) -> String {
        #"{"type":"string","title":"Other","description":"Type your own answer.","_meta":{"questionCustomAnswer":\#(marker)}}"#
    }

    @Test("the negotiated marker pairs each custom answer with its question, and submits under its own key")
    @MainActor
    func customAnswerPairsByMarker() throws {
        // Keys are swapped on purpose: only the marker may decide the pairing.
        let request = try questionForm("""
        "q0":\(Self.select),"q1":\(Self.select),
        "q0_custom":\(Self.other(#"{"version":1,"questionId":"q1"}"#)),
        "q1_custom":\(Self.other(#"{"version":1,"questionId":"q0"}"#))
        """)
        #expect(request.fieldGroups.map(\.field.key) == ["q0", "q1"])
        #expect(request.fieldGroups.map(\.note?.key) == ["q1_custom", "q0_custom"])
        #expect(request.fieldGroups[0].note?.noteLabel == "Other")

        let form = ACPUserInputFormState(request: request)
        form.toggle("A", for: request.fieldGroups[0].field)
        form.textValues["q1_custom"] = "typed"
        #expect(form.submittedContent() == ["q0": .string("A"), "q1_custom": .string("typed")])
    }

    @Test("an unusable marker, or none, leaves a field independent", arguments: [
        #"{"version":2,"questionId":"q0"}"#,
        #"{"questionId":"q0"}"#,
        #"{"version":1,"questionId":7}"#,
        #"{"version":1,"questionId":""}"#,
        #"{"version":1,"questionId":"missing"}"#,
        #"{"version":1,"questionId":"Other"}"#,
        #"true"#,
    ])
    func unusableMarkerStaysIndependent(marker: String) throws {
        let request = try questionForm("\"q0\":\(Self.select),\"Other\":\(Self.other(marker))")
        #expect(request.fieldGroups.map(\.field.key) == ["Other", "q0"])
        #expect(request.fieldGroups.allSatisfy { $0.note == nil })
    }

    @Test("a generic form field titled Other is never guessed to be an answer")
    func unmarkedOtherIsIndependent() throws {
        let request = try questionForm(#""q0":\#(Self.select),"q0_custom":{"type":"string","title":"Other"}"#)
        #expect(request.fieldGroups.map(\.field.key) == ["q0", "q0_custom"])
        #expect(request.fieldGroups.allSatisfy { $0.note == nil })
    }

    @Test("a marker on a choice field, or a chain of markers, can't hide a field")
    func markersCannotHideFields() throws {
        let chain = try questionForm("""
        "a":\(Self.other(#"{"version":1,"questionId":"b"}"#)),
        "b":\(Self.other(#"{"version":1,"questionId":"c"}"#)),
        "c":\(Self.select)
        """)
        #expect(chain.fieldGroups.map(\.field.key) == ["a", "c"])
        #expect(chain.fieldGroups.map(\.note?.key) == [nil, "b"])

        let choice = try questionForm(#"""
        "c":\#(Self.select),"d":{"type":"string","oneOf":[{"const":"x"}],"_meta":{"questionCustomAnswer":{"version":1,"questionId":"c"}}}
        """#)
        #expect(choice.fieldGroups.map(\.field.key) == ["c", "d"])
    }

    @Test("a note without its question stays its own group")
    func orphanNoteStaysAGroup() throws {
        let extra = #"""
        ,"stray":{"type":"string","_meta":{"codex":{"questionId":"missing","role":"user_note"}}}
        """#
        let request = try asyncRequest(extra: extra)
        #expect(request.fieldGroups.map(\.field.key).contains("stray"))
    }

    @Test("optional answer text matches the adapter replay", arguments: [
        (["question_0": "Staging"], "> Q0\n\nStaging"),
        (["question_0": "None of the above", "question_0_note": "  mine "], "> Q0\n\nmine"),
        (["question_0": "Staging", "question_0_note": "mine"], "> Q0\n\nStaging\n\nmine"),
        (["question_0": "Prod", "question_1": "free"], "> Q0\n\nProd\n\n> Q1\n\nfree"),
        (["question_0": "None of the above"], nil),
        (["question_0_note": "   "], nil),
        ([:], nil),
    ] as [([String: String], String?)])
    func optionalAnswerText(values: [String: String], expected: String?) throws {
        let request = try asyncRequest()
        let content = values.mapValues { ACPElicitationValue.string($0) }
        #expect(request.optionalAnswerTranscriptText(content) == expected)
    }

    @Test("optional answer text orders questions numerically and flattens titles")
    func optionalAnswerTextOrderingAndTitles() throws {
        let extra = #"""
        ,"question_10":{"type":"string","title":"ten"},
        "question_2":{"type":"string","title":"two\r\nlines"}
        """#
        let request = try asyncRequest(extra: extra)
        let text = request.optionalAnswerTranscriptText([
            "question_10": .string("b"), "question_2": .string("a"),
        ])
        #expect(text == "> two  lines\n\na\n\n> ten\n\nb")
    }
}
