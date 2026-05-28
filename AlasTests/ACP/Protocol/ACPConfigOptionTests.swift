import Foundation
import Testing
@testable import Alas

@Suite("ACPConfigOption")
struct ACPConfigOptionTests {
    @Test("decodes a select config option")
    func decodeSelect() throws {
        let json = """
        {
          "id": "effort",
          "name": "Effort",
          "type": "select",
          "category": "ThoughtLevel",
          "currentValue": "medium",
          "options": [
            { "id": "low", "name": "Low" },
            { "id": "medium", "name": "Medium" },
            { "id": "high", "name": "High", "description": "Use more reasoning" }
          ]
        }
        """.data(using: .utf8)!
        let opt = try JSONDecoder().decode(ACPConfigOption.self, from: json)
        #expect(opt.id == "effort")
        #expect(opt.name == "Effort")
        #expect(opt.type == "select")
        #expect(opt.category == "ThoughtLevel")
        #expect(opt.currentValue == "medium")
        #expect(opt.options.count == 3)
        #expect(opt.options[2].description == "Use more reasoning")
    }

    @Test("non-select type decodes with empty options")
    func decodeUnknownType() throws {
        let json = """
        { "id": "x", "name": "X", "type": "text", "currentValue": "" }
        """.data(using: .utf8)!
        let opt = try JSONDecoder().decode(ACPConfigOption.self, from: json)
        #expect(opt.type == "text")
        #expect(opt.options.isEmpty)
    }

    @Test("encodes setConfigOption params")
    func encodeSetParams() throws {
        let params = ACPSessionSetConfigOptionParams(sessionId: "s", configId: "effort", value: "high")
        let data = try JSONEncoder().encode(params)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"sessionId\":\"s\""))
        #expect(s.contains("\"configId\":\"effort\""))
        #expect(s.contains("\"value\":\"high\""))
    }
}
