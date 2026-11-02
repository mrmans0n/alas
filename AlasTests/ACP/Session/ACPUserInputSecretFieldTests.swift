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
