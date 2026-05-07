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

    @Test func updateEditorPathPersistsTabMetadata() throws {
        let (manager, _, _) = makeManager()
        let tab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")

        #expect(manager.updateEditorPath(worktreeId: "wt", tabId: tab.id, relativePath: "src/b.txt"))

        let updated = manager.tabs(forWorktree: "wt").first { $0.id == tab.id }
        #expect(updated?.title == "b.txt")
        #expect(updated?.relativeFilePath == "src/b.txt")
    }

    @Test func hasEditorCanExcludeCurrentTab() throws {
        let (manager, _, _) = makeManager()
        let first = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        _ = manager.appendEditor(worktreeId: "wt", title: "b.txt", relativePath: "b.txt")

        #expect(manager.hasEditor(worktreeId: "wt", relativePath: "a.txt"))
        #expect(!manager.hasEditor(worktreeId: "wt", relativePath: "a.txt", excluding: first.id))
        #expect(manager.hasEditor(worktreeId: "wt", relativePath: "b.txt", excluding: first.id))
    }

    @Test func saveAllOnlySavesDirtyBuffersAndReturnsErrors() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let a = manager.buffer(worktreeId: "wt", tabId: "ta", worktreeRoot: root, relativePath: "a.txt")
        _ = manager.buffer(worktreeId: "wt", tabId: "tb", worktreeRoot: root, relativePath: "b.txt")
        a.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")

        let errors = manager.saveAll()

        #expect(errors.isEmpty)
        #expect(a.dirty == false)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "zx")
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "y")
    }

    @Test func saveAllSavesUnloadedDirtySnapshots() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let tab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "a.txt",
            content: "edited\n",
            originalText: "x",
            originalMtime: Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: tab.id)

        let errors = manager.saveAll(worktreeRoots: ["wt": root])

        #expect(errors.isEmpty)
        #expect(manager.peekBuffer(tabId: tab.id) == nil)
        #expect(try store.read(worktreeId: "wt", tabId: tab.id) == nil)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "edited\n")
    }

    @Test func saveAllPreservesUnloadedSnapshotWhenSaveFails() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let tab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "a.txt",
            content: "edited\n",
            originalText: "x",
            originalMtime: Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: tab.id)
        try FileManager.default.removeItem(at: root)

        let errors = manager.saveAll(worktreeRoots: ["wt": root])

        #expect(errors.map(\.tabId) == [tab.id])
        #expect(manager.peekBuffer(tabId: tab.id) == nil)
        #expect(try store.read(worktreeId: "wt", tabId: tab.id) != nil)
    }
}
