import Foundation
import Testing
@testable import Alas

@Suite("LSPMessages")
struct LSPMessagesTests {
    @Test("encodes a request envelope with id, method, params")
    func encodeRequest() throws {
        let req = LSPRequest(
            id: .int(1),
            method: "initialize",
            params: AnyEncodable(["processId": 42 as Int])
        )
        let data = try JSONEncoder().encode(req)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"jsonrpc\":\"2.0\""))
        #expect(json.contains("\"id\":1"))
        #expect(json.contains("\"method\":\"initialize\""))
    }

    @Test("decodes a response with a result and the result Data round-trips into a structured type")
    func decodeResponseResult() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"hoverProvider":true}}}"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(LSPResponse.self, from: json)
        #expect(resp.id == .int(1))
        #expect(resp.error == nil)
        let result = try #require(resp.result)
        struct InitResult: Decodable { struct Caps: Decodable { let hoverProvider: Bool? }; let capabilities: Caps }
        let decoded = try JSONDecoder().decode(InitResult.self, from: result)
        #expect(decoded.capabilities.hoverProvider == true)
    }

    @Test("decodes a response with an error")
    func decodeResponseError() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(LSPResponse.self, from: json)
        #expect(resp.error?.code == -32601)
        #expect(resp.error?.message == "Method not found")
    }

    @Test("Position translates to/from line/column")
    func position() throws {
        let p = LSPPosition(line: 3, character: 7)
        let data = try JSONEncoder().encode(p)
        let p2 = try JSONDecoder().decode(LSPPosition.self, from: data)
        #expect(p == p2)
    }
}
