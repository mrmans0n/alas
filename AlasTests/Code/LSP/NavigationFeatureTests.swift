import AppKit
import Foundation
import Testing
@testable import Alas

@Suite("LSP navigation", .serialized)
struct NavigationFeatureTests {
    @Test @MainActor func referenceRequestsFollowTheCurrentWorktreeStoreAndClearCancelledLoading() async {
        let firstStore = EditorNavigationStore()
        let secondStore = EditorNavigationStore()
        var activeStore = firstStore
        var continuations: [CheckedContinuation<(LSPClient, EditorRequestContext)?, Never>] = []
        let feature = NavigationFeature(
            store: { activeStore },
            synchronizeRequest: { _ in
                await withCheckedContinuation { continuations.append($0) }
            },
            isContextCurrent: { _ in true }
        )

        feature.perform(.references, range: NSRange(location: 0, length: 0))
        await Task.yield()
        #expect(firstStore.isLoading)

        activeStore = secondStore
        feature.perform(.references, range: NSRange(location: 0, length: 0))
        await Task.yield()
        #expect(!firstStore.isLoading)
        #expect(secondStore.isLoading)

        continuations.last?.resume(returning: nil)
        await waitUntil { !secondStore.isLoading }
        #expect(!secondStore.isLoading)
        continuations.first?.resume(returning: nil)
    }

    @Test @MainActor func staleReferenceResponsesClearLoading() async {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        let document = EditorDocumentID(host: nil, worktreeID: "worktree", uri: "file:///tmp/current.swift")
        let context = EditorRequestContext(
            document: document,
            version: 1,
            serverGeneration: UUID(),
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0))
        )
        let store = EditorNavigationStore()
        let existing = EditorNavigationTarget(document: document, position: LSPPosition(line: 9, character: 2))
        store.replaceResults([existing])
        var didCheckStaleContext = false
        transport.onSend = { _ in }
        let feature = NavigationFeature(
            store: { store },
            synchronizeRequest: { _ in (client, context) },
            isContextCurrent: { _ in
                didCheckStaleContext = true
                return false
            }
        )

        feature.perform(.references, range: NSRange(location: 0, length: 0))
        await waitUntil { !transport.sent.isEmpty }
        transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":[{"uri":"file:///tmp/stale.swift","range":{"start":{"line":2,"character":0},"end":{"line":2,"character":3}}}]}"#)
        await waitUntil { didCheckStaleContext }

        #expect(!store.isLoading)
        #expect(store.results == [existing])
        transport.finish()
    }

    @Test @MainActor func directCommandClickDefinitionSupersedesPendingReferences() async {
        let store = EditorNavigationStore()
        var continuation: CheckedContinuation<(LSPClient, EditorRequestContext)?, Never>?
        let navigation = NavigationFeature(
            store: { store },
            synchronizeRequest: { _ in
                await withCheckedContinuation { continuation = $0 }
            },
            isContextCurrent: { _ in true }
        )
        navigation.perform(.references, range: NSRange(location: 0, length: 0))
        await Task.yield()
        #expect(store.isLoading)

        let textView = makeTextView("symbol")
        let definition = DefinitionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/current.swift" },
            openTarget: { _, _, _, _ in },
            cancelPendingNavigation: { navigation.cancelPendingRequest() }
        )

        textView.triggerCommandClick(atUTF16Offset: 0)

        #expect(!store.isLoading)
        continuation?.resume(returning: nil)
        _ = definition
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: Int = 100
    ) async {
        for _ in 0 ..< timeout {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func makeTextView(_ text: String) -> CodeTextView {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = CodeTextView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            textContainer: container
        )
        _ = layoutManager.glyphRange(for: container)
        return textView
    }

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
