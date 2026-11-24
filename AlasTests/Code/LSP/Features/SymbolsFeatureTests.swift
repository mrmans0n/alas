import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct SymbolsFeatureTests {
    @Test func ignoresStaleDocumentSymbolResponse() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        let feature = SymbolsFeature()
        let oldURI = "file:///tmp/old.swift"
        let newURI = "file:///tmp/new.swift"

        let oldRefresh = Task { @MainActor in
            await feature.refresh(client: client, uri: oldURI)
        }
        try await eventually("the old document symbol request") { transport.sent.count == 1 }
        let oldID = try #require(transport.sent.first.flatMap { Self.requestID(in: $0, uri: oldURI) })

        let newRefresh = Task { @MainActor in
            await feature.refresh(client: client, uri: newURI)
        }
        try await eventually("the new document symbol request") { transport.sent.count == 2 }
        let newID = try #require(transport.sent.last.flatMap { Self.requestID(in: $0, uri: newURI) })
        transport.deliverFrame(Self.symbolResponse(id: newID, name: "NewSymbol"))
        await newRefresh.value
        transport.deliverFrame(Self.symbolResponse(id: oldID, name: "OldSymbol"))
        await oldRefresh.value

        #expect(feature.symbols.map(\.name) == ["NewSymbol"])
    }

    private static func symbolResponse(id: Int, name: String) -> String {
        """
        {"jsonrpc":"2.0","id":\(id),"result":[{"name":"\(name)","kind":12,"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}]}
        """
    }

    private static func requestID(in json: String, uri: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "textDocument/documentSymbol",
              let params = object["params"] as? [String: Any],
              let document = params["textDocument"] as? [String: Any],
              document["uri"] as? String == uri
        else { return nil }
        return object["id"] as? Int
    }
}
