import Testing
import Foundation
@testable import Alas

private func snippetReaderIsOnMainThread() -> Bool { Thread.isMainThread }

@Suite(.serialized)
struct DefinitionSnippetCacheTests {
    @Test @MainActor func snippetsCoalesceDocumentsBoundQueueAndRejectReplacedSearch() async throws {
        let probe = SnippetReadProbe()
        let store = EditorNavigationStore(snippetReader: { document, _ in
            #expect(!snippetReaderIsOnMainThread())
            return await probe.read(document)
        })
        let targets = (0..<80).flatMap { index in
            (0..<2).map { line in EditorNavigationTarget(document: .init(host: nil, worktreeID: "w", uri: "file:///snippet/\(index)"), position: .init(line: line, character: 0)) }
        }
        store.replaceResults(targets)
        targets.forEach { store.loadSnippet(for: $0) }
        for _ in 0..<200 where await probe.startedCount < 4 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await probe.startedCount == 4)
        #expect(store.activeSnippetDocumentCount == 4)
        #expect(store.pendingSnippetDocumentCount == 64)
        #expect(await probe.readsPerDocument.values.allSatisfy { $0 == 1 })
        #expect(await probe.allReadsOffMain)
        let replacement = EditorNavigationTarget(document: .init(host: nil, worktreeID: "w", uri: "file:///replacement"), position: .init(line: 0, character: 0))
        store.replaceResults([replacement])
        store.loadSnippet(for: replacement)
        #expect(store.activeSnippetDocumentCount == 4)
        await probe.releaseAll("old\nold")
        for _ in 0..<200 where await probe.startedCount < 5 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await probe.startedCount == 5)
        await probe.releaseAll("fresh")
        for _ in 0..<200 where store.snippets[replacement] == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.snippets == [replacement: "fresh"])
        #expect(await probe.maximumActive == 4)
    }

    @Test(arguments: [64, 1_048_576]) @MainActor
    func snippetCacheBoundsDocumentsAndRetainedSourceBytes(documentBytes: Int) async throws {
        let text = "line\n" + String(repeating: "x", count: documentBytes - 5)
        let store = EditorNavigationStore(snippetReader: { _, _ in text })
        let targets = (0..<68).map { index in EditorNavigationTarget(document: .init(host: nil, worktreeID: "w", uri: "file:///cache/\(index)"), position: .init(line: 0, character: 0)) }
        store.replaceResults(targets)
        targets.forEach { store.loadSnippet(for: $0) }
        for _ in 0..<500 where store.activeSnippetDocumentCount > 0 || store.pendingSnippetDocumentCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.snippets.count == targets.count)
        #expect(store.cachedSnippetDocumentCount <= 64)
        #expect(store.retainedSnippetBytes <= 8_388_608)
        #expect(store.snippets.values.allSatisfy { $0 == "line" })
    }

    @Test @MainActor func worktreeSnippetsUseDirtyBuffersAndRefreshTheirCachedGeneration() async throws {
        let url = try tempFile("saved\nsecond")
        defer { try? FileManager.default.removeItem(at: url) }
        let root = url.deletingLastPathComponent()
        let tabs = TabsManager()
        let buffer = tabs.buffer(worktreeId: "snippet", tabId: "snippet", worktreeRoot: root, relativePath: url.lastPathComponent)
        await buffer.awaitLoadForTesting()
        buffer.stopWatching()
        defer { buffer.close(persistDirtySnapshot: false) }
        let target = EditorNavigationTarget(document: .init(host: nil, worktreeID: "snippet", uri: url.lspURI), position: .init(line: 0, character: 0))
        let store = tabs.navigationStore(forWorktreeId: "snippet")
        store.replaceResults([target])
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "dirty")
        store.loadSnippet(for: target)
        for _ in 0..<200 where store.snippets[target] == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.snippets[target] == "dirty")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "newer")
        store.loadSnippet(for: target)
        for _ in 0..<200 where store.snippets[target] == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.snippets[target] == "newer")
        #expect(try String(contentsOf: url, encoding: .utf8) == "saved\nsecond")
    }

    @Test @MainActor func oversizedNavigationSnippetRemainsUnavailableAndNavigable() async throws {
        let url = try tempFile(String(repeating: "x", count: 2 * 1024 * 1024))
        defer { try? FileManager.default.removeItem(at: url) }
        let target = EditorNavigationTarget(document: .init(host: nil, worktreeID: "w", uri: url.lspURI), position: .init(line: 0, character: 0))
        let store = EditorNavigationStore()
        store.replaceResults([target])
        store.loadSnippet(for: target)
        for _ in 0..<200 where store.snippets[target] == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.results == [target])
        let unavailable = store.snippets[target] == "Snippet unavailable"
        #expect(unavailable)
    }

    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippet-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func returnsRequestedLine() throws {
        let url = try tempFile("first\nsecond line\nthird\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = DefinitionSnippetCache()
        #expect(cache.line(at: url, line: 1) == "second line")
    }

    @Test func returnsEmptyForOutOfRange() throws {
        let url = try tempFile("only\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = DefinitionSnippetCache()
        #expect(cache.line(at: url, line: 99) == "")
    }

    @Test func cachesRepeatedReads() throws {
        let url = try tempFile("x\ny\nz\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = DefinitionSnippetCache()
        _ = cache.line(at: url, line: 1)
        // Mutate the file; cache should still return the original.
        try "DIFFERENT\nDATA\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(cache.line(at: url, line: 1) == "y")
    }
}

actor SnippetReadProbe {
    private var waiters: [EditorDocumentID: CheckedContinuation<String?, Never>] = [:]
    private(set) var readsPerDocument: [EditorDocumentID: Int] = [:]
    private(set) var startedCount = 0
    private(set) var maximumActive = 0
    private(set) var allReadsOffMain = true

    func read(_ document: EditorDocumentID) async -> String? {
        allReadsOffMain = allReadsOffMain && !Thread.isMainThread
        startedCount += 1
        readsPerDocument[document, default: 0] += 1
        return await withCheckedContinuation { continuation in
            waiters[document] = continuation
            maximumActive = max(maximumActive, waiters.count)
        }
    }

    func releaseAll(_ text: String) {
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume(returning: text) }
    }
}
