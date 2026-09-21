import Foundation
import Testing
@testable import Alas

@Suite("ACPUserInput secret field metadata")
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
}
