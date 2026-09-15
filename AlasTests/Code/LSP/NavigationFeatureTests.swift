import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Alas

@Suite("LSP navigation", .serialized)
struct NavigationFeatureTests {
    @Test(arguments: ["unavailable", "unsupported", "empty", "failure", "cancel"])
    @MainActor func mountedDefinitionStatusIsImmediateCancellableAndDistinct(state: String) async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        transport.onSend = { sent in
            guard let frame = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = frame["id"] else { return }
            var response: [String: LSPJSONValue] = ["id": id]
            if frame["method"] == .string("initialize") {
                response["result"] = .object(["capabilities": .object(["definitionProvider": .bool(state != "unsupported")])])
            } else if state == "failure" {
                response["error"] = .object(["code": .number("-32603"), "message": .string("Navigation fixture failure")])
            } else { response["result"] = .array([]) }
            transport.deliverFrame(String(decoding: try! LSPJSONValue.object(response).encodedData(), as: UTF8.self))
        }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///fixture")
        try await client.initialize()
        let view = makeTextView("symbol")
        let window = NSWindow(contentRect: view.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil)
        window.contentView = nil }
        let started = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish() }
        var resume: CheckedContinuation<(LSPClient, EditorRequestContext)?, Never>?
        let context = EditorRequestContext(document: .init(host: nil, worktreeID: "fixture", uri: "file:///fixture/a.swift"), version: 1, serverGeneration: UUID(), range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0)))
        let feature = DefinitionFeature(textView: view, getClient: { client }, getURI: { context.document.uri }, openTarget: { _, _, _, _ in Issue.record("Unexpected navigation") }, synchronizeRequest: { _ in
            await withCheckedContinuation { resume = $0
            started.continuation.yield(()) }
        })
        defer { feature.notifyCaretChanged() }
        func status() throws -> DefinitionRequestStatusView {
            let popover = try #require(Mirror(reflecting: feature).children.first { $0.label == "popover" }?.value as? NSPopover)
            return try #require(popover.contentViewController as? NSHostingController<DefinitionRequestStatusView>).rootView
        }
        view.triggerCommandClick(atUTF16Offset: 1)
        let original = try status()
        #expect(original.loading)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        if state == "cancel" {
            original.cancel()
            resume?.resume(returning: (client, context))
            view.triggerCommandClick(atUTF16Offset: 1)
            _ = await iterator.next()
            original.cancel()
            #expect(try status().loading)
            resume?.resume(returning: nil)
        } else { resume?.resume(returning: state == "unavailable" ? nil : (client, context)) }
        for _ in 0..<200 where try status().loading { try await Task.sleep(for: .milliseconds(10)) }
        let result = try status()
        #expect(!result.loading)
        switch state {
        case "unavailable", "cancel": #expect(result.message == "Language server unavailable")
        case "unsupported": #expect(result.message.contains("not supported"))
        case "failure": #expect(result.message.contains("Navigation fixture failure"))
        default: #expect(result.message == "No navigation targets found")
        }
    }

    @Test @MainActor func rerunKeepsOriginalQueryAfterCaretChangesAndRejectsStaleAnchor() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let requests = AsyncStream<LSPJSONValue>.makeStream()
        defer { requests.continuation.finish() }
        transport.onSend = { sent in
            guard let frame = try? LSPJSONValue.decode(from: Data(sent.utf8)), frame["method"] == .string("textDocument/references") else { return }
            requests.continuation.yield(frame)
            transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["id": frame["id"]!, "result": .array([])]).encodedData(), as: UTF8.self))
        }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///original")
        let document = EditorDocumentID(host: nil, worktreeID: "original", uri: "file:///original/a.swift")
        var valid = true
        let original = EditorRequestContext(document: document, version: 1, serverGeneration: UUID(), range: .init(start: .init(line: 3, character: 7), end: .init(line: 3, character: 7)))
        let store = EditorNavigationStore()
        let feature = NavigationFeature(store: { store }, synchronizeRequest: { _ in (client, original) }, isContextCurrent: { _ in valid })
        feature.perform(.references, range: .init(location: 12, length: 0))
        var iterator = requests.stream.makeAsyncIterator()
        _ = try #require(await iterator.next())
        await waitUntil { !store.isLoading }
        let unrelatedView = makeTextView("unrelated caret")
        unrelatedView.setSourceSelectedRange(.init(location: 9, length: 0))
        store.rerunReferences()
        let rerun = try #require(await iterator.next())
        #expect(rerun["params"]?["textDocument"]?["uri"] == .string(document.uri))
        #expect(rerun["params"]?["position"]?["line"] == .number("3"))
        #expect(rerun["params"]?["position"]?["character"] == .number("7"))
        await waitUntil { !store.isLoading }
        valid = false
        store.rerunReferences()
        #expect(store.statusMessage?.contains("original reference query is stale") == true)
        #expect(!store.isLoading)
    }

    @Test @MainActor func resultSelectionFollowsDisplayOrderAndStopsAtEnds() {
        let store = EditorNavigationStore()
        let a = EditorDocumentID(host: nil, worktreeID: "w", uri: "file:///a")
        let first = EditorNavigationTarget(document: a, position: .init(line: 2, character: 0))
        let last = EditorNavigationTarget(document: a, position: .init(line: 9, character: 0))
        store.replaceResults([last, first])
        #expect(store.selectedResult == first)
        store.moveResultSelection(by: 1)
        #expect(store.selectedResult == last)
        store.moveResultSelection(by: 1)
        #expect(store.selectedResult == last)
        store.moveResultSelection(by: -1)
        #expect(store.selectedResult == first)
    }

    @Test(arguments: [false, true]) @MainActor
    func definitionPickerUsesSharedDirtySnippetsAndDropsSupersededLoads(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("definition-snippets-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dirtyURL = root.appendingPathComponent("dirty.swift")
        let diskURL = root.appendingPathComponent("disk.swift")
        try Data("saved".utf8).write(to: dirtyURL)
        try Data("small disk snippet".utf8).write(to: diskURL)
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "dirty.swift")
        await buffer.awaitLoadForTesting()
        buffer.stopWatching()
        defer { buffer.close(persistDirtySnapshot: false) }
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "dirty buffer snippet")
        let probe = SnippetReadProbe()
        let store = EditorNavigationStore(openBuffer: { $0.uri == dirtyURL.lspURI ? buffer : nil }, snippetReader: { document, limit in
            _ = await probe.read(document)
            return await EditorNavigationStore.readSnippetDocument(document, limit: limit)
        })
        let transport = FakeTransport()
        defer { transport.finish() }
        // The LSP client's executor invokes this callback, not the main actor.
        transport.onSend = { @Sendable sent in
            guard let frame = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = frame["id"] else { return }
            let result: LSPJSONValue
            if frame["method"] == .string("initialize") { result = .object(["capabilities": .object(["definitionProvider": .bool(true)])]) }
            else { result = .array([dirtyURL, diskURL].map { .object(["uri": .string($0.lspURI), "range": .object(["start": .object(["line": .number("0"), "character": .number("0")]), "end": .object(["line": .number("0"), "character": .number("1")])])]) }) }
            transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["id": id, "result": result]).encodedData(), as: UTF8.self))
        }
        let client = LSPClient(transport: transport, language: "swift", rootURI: root.lspURI)
        try await client.initialize()
        let textView = makeTextView("symbol")
        let window = NSWindow(contentRect: textView.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = textView
        window.orderFront(nil)
        defer { window.orderOut(nil)
            window.contentView = nil
        }
        let context = EditorRequestContext(document: .init(host: nil, worktreeID: "w", uri: root.appendingPathComponent("source.swift").lspURI), version: 1, serverGeneration: UUID(), range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0)))
        var opened = false
        let feature = DefinitionFeature(textView: textView, getClient: { client }, getURI: { context.document.uri }, openTarget: { _, _, _, _ in opened = true }, synchronizeRequest: { _ in (client, context) }, snippetStore: { store })
        textView.triggerCommandClick(atUTF16Offset: 1)
        await waitUntil { store.snippets.values.contains("dirty buffer snippet") }
        #expect(store.snippets.values.contains("dirty buffer snippet"))
        for _ in 0..<200 where await probe.startedCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await probe.startedCount == 1)
        let popover = try #require(Mirror(reflecting: feature).children.first { $0.label == "popover" }?.value as? NSPopover)
        let picker = try #require(popover.contentViewController as? NSHostingController<DefinitionPicker>).rootView
        if cancel { feature.notifyCaretChanged() }
        await probe.releaseAll("ready")
        await waitUntil { store.activeSnippetDocumentCount == 0 }
        if cancel {
            #expect(store.snippets.isEmpty)
            picker.onChoose(0)
            #expect(!opened)
        } else {
            #expect(store.snippets.values.contains("small disk snippet"))
            picker.onChoose(0)
            #expect(opened)
        }
        feature.notifyCaretChanged()
    }

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

    @Test @MainActor func staleResultsRemainMarkedUntilRerunReplacesThem() async {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        let document = EditorDocumentID(host: nil, worktreeID: "worktree", uri: "file:///tmp/current.swift")
        let context = EditorRequestContext(
            document: document,
            version: 2,
            serverGeneration: UUID(),
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0))
        )
        let store = EditorNavigationStore()
        let stale = EditorNavigationTarget(document: document, position: LSPPosition(line: 9, character: 2))
        let refreshed = EditorNavigationTarget(document: document, position: LSPPosition(line: 3, character: 1))
        store.replaceResults([stale])
        store.markResultsStale()
        let feature = NavigationFeature(
            store: { store },
            synchronizeRequest: { _ in (client, context) },
            isContextCurrent: { _ in true }
        )

        feature.perform(.references, range: NSRange(location: 0, length: 0))
        await waitUntil { !transport.sent.isEmpty }

        #expect(store.isLoading)
        #expect(store.results == [stale])
        #expect(store.resultsAreStale)

        transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":[{"uri":"file:///tmp/current.swift","range":{"start":{"line":3,"character":1},"end":{"line":3,"character":4}}}]}"#)
        await waitUntil { !store.isLoading }

        #expect(store.results == [refreshed])
        #expect(!store.resultsAreStale)
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
