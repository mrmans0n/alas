// AlasTests/EditorBufferStoreTests.swift
import Testing
import Foundation
@testable import Alas

@MainActor
struct EditorBufferStoreTests {
    private func makeStore() -> (EditorBufferStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-buffer-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (EditorBufferStore(rootOverride: tmp), tmp)
    }

    @Test func snapshotRoundTripPreservesContent() throws {
        let (store, _) = makeStore()
        let snap = EditorBufferStore.Snapshot(
            relativePath: "src/foo.swift",
            content: "edited\n",
            originalText: "original\n",
            originalMtime: Date(timeIntervalSince1970: 1_700_000_000),
            lineEnding: .lf
        )
        try store.write(snap, worktreeId: "wt-1", tabId: "tab-1")
        let loaded = try store.read(worktreeId: "wt-1", tabId: "tab-1")
        #expect(loaded == snap)
    }

    @Test func readMissingReturnsNil() throws {
        let (store, _) = makeStore()
        #expect(try store.read(worktreeId: "wt-1", tabId: "absent") == nil)
    }

    @Test func discardRemovesFile() throws {
        let (store, _) = makeStore()
        let snap = EditorBufferStore.Snapshot(
            relativePath: "x.txt", content: "hi", originalText: "",
            originalMtime: Date(), lineEnding: .lf
        )
        try store.write(snap, worktreeId: "wt", tabId: "t")
        store.discard(worktreeId: "wt", tabId: "t")
        #expect(try store.read(worktreeId: "wt", tabId: "t") == nil)
    }

    @Test func corruptJSONReturnsNilAndDeletes() throws {
        let (store, root) = makeStore()
        let dir = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("t.json")
        try "{this is not json".write(to: file, atomically: true, encoding: .utf8)
        #expect(try store.read(worktreeId: "wt", tabId: "t") == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func crlfRoundTrips() throws {
        let (store, _) = makeStore()
        let snap = EditorBufferStore.Snapshot(
            relativePath: "win.txt",
            content: "edited\r\nlines\r\n",
            originalText: "lines\r\n",
            originalMtime: Date(),
            lineEnding: .crlf
        )
        try store.write(snap, worktreeId: "wt", tabId: "t")
        #expect(try store.read(worktreeId: "wt", tabId: "t") == snap)
    }

    @Test func externalBufferIsCachedSeparately() throws {
        let (store, _) = makeStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-\(UUID().uuidString).h")
        try "header content\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let a = store.externalBuffer(worktreeId: "w1", absoluteURL: url)
        let b = store.externalBuffer(worktreeId: "w1", absoluteURL: url)
        #expect(a === b)  // same instance reused

        // Different worktreeId → distinct buffer.
        let c = store.externalBuffer(worktreeId: "w2", absoluteURL: url)
        #expect(c !== a)
    }

    @Test func externalBufferIsReleasedOnDiscard() throws {
        let (store, _) = makeStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-discard-\(UUID().uuidString).h")
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let a = store.externalBuffer(worktreeId: "w", absoluteURL: url)
        store.discardExternalBuffer(worktreeId: "w", absoluteURL: url)
        let b = store.externalBuffer(worktreeId: "w", absoluteURL: url)
        #expect(a !== b)  // a was discarded; b is a fresh instance
    }
}
