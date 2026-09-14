import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct SemanticTokensClientTests {
    @Test(arguments: [#"{"data":[0,0,1,0,true]}"#, #"{"data":[0,0,1,0,0.5]}"#, #"{"data":[0,0,1,0,-1]}"#, #"{"data":[0,0,1,0,2147483648]}"#, #"{"edits":[]}"#])
    func rejectsMalformedWireData(_ wire: String) {
        #expect(throws: (any Error).self) { try LSPClient.decodeSemanticResponse(Data(wire.utf8)) }
    }

    @Test func negotiatesRangeAndFullWithoutDeltaAndAcknowledgesRefreshBeforeWork() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            guard let request = try? LSPJSONValue.decode(from: Data(sent.utf8)),
                  let id = request["id"], let method = request["method"]?.stringValue else { return }
            let result: LSPJSONValue
            if method == "initialize" {
                result = .object(["capabilities": .object(["semanticTokensProvider": .object([
                    "legend": .object(["tokenTypes": .array([.string("function")]), "tokenModifiers": .array([])]),
                    "range": .object([:]), "full": .object(["delta": .bool(true)])
                ])])])
            } else {
                result = .object(["data": .array([0, 0, 2, 0, 0].map { .number(String($0)) })])
            }
            let frame = try! LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).encodedData()
            transport.deliverFrame(String(decoding: frame, as: UTF8.self))
        }
        try await client.initialize()
        let initialize = try LSPJSONValue.decode(from: Data(try #require(transport.sent.first).utf8))
        let advertised = initialize["params"]?["capabilities"]?["textDocument"]?["semanticTokens"]
        #expect(advertised?["requests"]?["full"]?["delta"] == .bool(false))
        #expect(advertised?["multilineTokenSupport"] == .bool(false))
        #expect(advertised?["overlappingTokenSupport"] == .bool(false))
        let range = LSPRange(start: .init(line: 2, character: 0), end: .init(line: 3, character: 0))
        #expect(try await client.semanticTokens(uri: "file:///tmp/a", range: range) == [0, 0, 2, 0, 0])
        let request = try LSPJSONValue.decode(from: Data(try #require(transport.sent.last).utf8))
        #expect(request["method"] == .string("textDocument/semanticTokens/range"))
        #expect(request["params"]?["range"]?["start"]?["line"] == .number("2"))
        let refreshes = await client.subscribeSemanticRefreshes()
        transport.deliverFrame(#"{"jsonrpc":"2.0","id":"refresh","method":"workspace/semanticTokens/refresh"}"#)
        for await _ in refreshes {
            let reply = try LSPJSONValue.decode(from: Data(try #require(transport.sent.last).utf8))
            #expect(reply["id"] == .string("refresh"))
            #expect(reply["result"] == .null)
            break
        }
    }

    @Test func fullOnlyProviderUsesFullRequest() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            let method = (try? LSPJSONValue.decode(from: Data(sent.utf8)))?["method"]?.stringValue
            if method == "initialize" {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"semanticTokensProvider":{"legend":{"tokenTypes":["variable"],"tokenModifiers":[]},"full":true}}}}"#)
            } else if method == "textDocument/semanticTokens/full" {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":2,"result":null}"#)
            }
        }
        try await client.initialize()
        let range = LSPRange(start: .init(line: 0, character: 0), end: .init(line: 0, character: 1))
        #expect(try await client.semanticTokens(uri: "file:///tmp/a", range: range).isEmpty)
        let request = try LSPJSONValue.decode(from: Data(try #require(transport.sent.last).utf8))
        #expect(request["method"] == .string("textDocument/semanticTokens/full"))
    }
}
