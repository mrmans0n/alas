import Foundation
import Testing
@testable import Alas

@Suite("LSP navigation", .serialized)
struct NavigationFeatureTests {
    @Test @MainActor func equalPathsOnDifferentHostsStaySeparate() {
        let store = EditorNavigationStore()
        let position = LSPPosition(line: 0, character: 0)

        store.replaceResults(["host-a", "host-b"].map {
            EditorNavigationTarget(
                document: EditorDocumentID(host: $0, worktreeID: "w", uri: "file:///src/main.swift"),
                position: position
            )
        })

        #expect(store.groupedResults.count == 2)
    }

    @Test("typed navigation decodes null, locations, and location links")
    func typedNavigationDecodesProtocolResultShapes() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        let position = LSPPosition(line: 4, character: 12)
        var responseIndex = 0
        let responses = [
            #"{"jsonrpc":"2.0","id":1,"result":null}"#,
            #"{"jsonrpc":"2.0","id":2,"result":{"uri":"file:///tmp/one.swift","range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}}}}"#,
            #"{"jsonrpc":"2.0","id":3,"result":[{"uri":"file:///tmp/two.swift","range":{"start":{"line":3,"character":0},"end":{"line":3,"character":7}}}]}"#,
            #"{"jsonrpc":"2.0","id":4,"result":[{"targetUri":"file:///tmp/three.swift","targetRange":{"start":{"line":8,"character":0},"end":{"line":8,"character":9}},"targetSelectionRange":{"start":{"line":8,"character":4},"end":{"line":8,"character":9}}}]}"#
        ]
        transport.onSend = { _ in
            responseIndex += 1
            transport.deliverFrame(responses[responseIndex - 1])
        }

        #expect(try await client.definition(uri: "file:///tmp/current.swift", position: position).isEmpty)
        #expect(try await client.typeDefinition(uri: "file:///tmp/current.swift", position: position) == [
            LSPLocation(
                uri: "file:///tmp/one.swift",
                range: LSPRange(start: LSPPosition(line: 1, character: 2), end: LSPPosition(line: 1, character: 5))
            )
        ])
        #expect(try await client.implementation(uri: "file:///tmp/current.swift", position: position) == [
            LSPLocation(
                uri: "file:///tmp/two.swift",
                range: LSPRange(start: LSPPosition(line: 3, character: 0), end: LSPPosition(line: 3, character: 7))
            )
        ])
        #expect(try await client.references(uri: "file:///tmp/current.swift", position: position, includeDeclaration: true) == [
            LSPLocation(
                uri: "file:///tmp/three.swift",
                range: LSPRange(start: LSPPosition(line: 8, character: 4), end: LSPPosition(line: 8, character: 9))
            )
        ])
        #expect(transport.sent.last?.contains(#""includeDeclaration":true"#) == true)
        transport.finish()
    }
}
