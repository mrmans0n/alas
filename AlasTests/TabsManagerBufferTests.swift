import Testing
import Foundation
@testable import Alas

@MainActor
@Suite(.serialized)
struct TabsManagerBufferTests {
    private func tempWorktree() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-tabs-buffer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManager() -> (TabsManager, EditorBufferStore, URL) {
        let storeRoot = tempWorktree()
        let store = EditorBufferStore(rootOverride: storeRoot)
        let manager = TabsManager(bufferStore: store)
        return (manager, store, storeRoot)
    }

    @Test func bufferReturnsSameInstanceAcrossCalls() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let b1 = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        let b2 = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        #expect(b1 === b2)
    }

    @Test func closingDirtyBufferDiscardsSnapshotAndBuffer() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let buffer = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "edited ")
        buffer.snapshotNow()
        manager.discardBuffer(worktreeId: "wt", tabId: "t1")
        #expect(manager.peekBuffer(tabId: "t1") == nil)
        #expect(try store.read(worktreeId: "wt", tabId: "t1") == nil)
    }

    @Test func dirtyTabsReportsAcrossWorktrees() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let a = manager.buffer(worktreeId: "wt", tabId: "ta", worktreeRoot: root, relativePath: "a.txt")
        _ = manager.buffer(worktreeId: "wt", tabId: "tb", worktreeRoot: root, relativePath: "b.txt")
        a.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")
        let dirty = manager.dirtyTabIds()
        #expect(dirty == ["ta"])
    }

    @Test func snapshotDirtyBuffersForQuitWritesOnlyDirty() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let a = manager.buffer(worktreeId: "wt", tabId: "ta", worktreeRoot: root, relativePath: "a.txt")
        _ = manager.buffer(worktreeId: "wt", tabId: "tb", worktreeRoot: root, relativePath: "b.txt")
        a.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")
        manager.snapshotDirtyBuffersForQuit()
        #expect(try store.read(worktreeId: "wt", tabId: "ta") != nil)
        #expect(try store.read(worktreeId: "wt", tabId: "tb") == nil)
    }
}
