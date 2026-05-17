import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct SymbolsFeatureTests {
    @Test func ignoresStaleDocumentSymbolResponse() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        let feature = SymbolsFeature()

        transport.onSend = { sent in
            guard let id = Self.requestID(in: sent) else { return }
            if sent.contains(#""uri":"file:///tmp/old.swift""#) {
                Task {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    transport.deliverFrame(Self.symbolResponse(id: id, name: "OldSymbol"))
                }
            } else if sent.contains(#""uri":"file:///tmp/new.swift""#) {
                transport.deliverFrame(Self.symbolResponse(id: id, name: "NewSymbol"))
            }
        }

        let oldRefresh = Task { @MainActor in
            await feature.refresh(client: client, uri: "file:///tmp/old.swift")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let newRefresh = Task { @MainActor in
            await feature.refresh(client: client, uri: "file:///tmp/new.swift")
        }
        await oldRefresh.value
        await newRefresh.value

        #expect(feature.symbols.map(\.name) == ["NewSymbol"])
        transport.finish()
    }

    private static func symbolResponse(id: Int, name: String) -> String {
        """
        {"jsonrpc":"2.0","id":\(id),"result":[{"name":"\(name)","kind":12,"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}]}
        """
    }

    private static func requestID(in json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["id"] as? Int
    }
}
