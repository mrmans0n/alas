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
}
