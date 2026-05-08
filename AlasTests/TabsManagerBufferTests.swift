import Testing
import Foundation
import Darwin
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

    @Test func buffersForSamePathShareOneInstanceAcrossTabs() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()

        let first = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        let second = manager.buffer(worktreeId: "wt", tabId: "t2", worktreeRoot: root, relativePath: "a.txt")
        first.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")

        #expect(first === second)
        #expect(second.storage.string == "zx")
        #expect(manager.dirtyTabIds().sorted() == ["t1", "t2"])
    }

    @Test func closingOneTabForSharedPathKeepsBufferForOtherTab() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let first = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        _ = manager.buffer(worktreeId: "wt", tabId: "t2", worktreeRoot: root, relativePath: "a.txt")
        first.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")

        manager.discardBuffer(worktreeId: "wt", tabId: "t1")

        #expect(manager.peekBuffer(tabId: "t1") == nil)
        #expect(manager.peekBuffer(tabId: "t2") === first)
        #expect(manager.peekBuffer(tabId: "t2")?.storage.string == "zx")
    }

    @Test func externalRenameIntoOpenPathDoesNotReplaceDestinationBuffer() async throws {
        let root = tempWorktree()
        let oldURL = root.appendingPathComponent("a.txt")
        let destinationURL = root.appendingPathComponent("b.txt")
        try "a\n".write(to: oldURL, atomically: true, encoding: .utf8)
        try "b\n".write(to: destinationURL, atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let source = manager.buffer(worktreeId: "wt", tabId: "ta", worktreeRoot: root, relativePath: "a.txt")
        let destination = manager.buffer(worktreeId: "wt", tabId: "tb", worktreeRoot: root, relativePath: "b.txt")
        source.storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "mine")
        destination.storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "dirty")

        #expect(Darwin.rename(oldURL.path, destinationURL.path) == 0)
        for _ in 0..<20 where source.conflict == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(manager.peekBuffer(tabId: "tb") === destination)
        #expect(destination.storage.string == "dirty\n")
        #expect(destination.dirty == true)
        #expect(source.relativePath == "a.txt")
        #expect(source.conflict == .deletedOnDisk)
    }

    @Test func inAppRenameIntoOpenPathDoesNotReplaceDestinationBuffer() throws {
        let root = tempWorktree()
        let sourceURL = root.appendingPathComponent("a.txt")
        let destinationURL = root.appendingPathComponent("b.txt")
        try "a\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "b\n".write(to: destinationURL, atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let source = manager.buffer(worktreeId: "wt", tabId: "ta", worktreeRoot: root, relativePath: "a.txt")
        let destination = manager.buffer(worktreeId: "wt", tabId: "tb", worktreeRoot: root, relativePath: "b.txt")
        destination.storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "dirty")
        try FileManager.default.removeItem(at: destinationURL)

        #expect(throws: (any Error).self) {
            try source.moveTo(relativePath: "b.txt")
        }

        #expect(manager.peekBuffer(tabId: "tb") === destination)
        #expect(destination.storage.string == "dirty\n")
        #expect(destination.dirty == true)
        #expect(source.relativePath == "a.txt")
    }

    @Test func inAppRenameIntoUnloadedSnapshotPathIsRejected() throws {
        let root = tempWorktree()
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let sourceTab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let destinationTab = manager.appendEditor(worktreeId: "wt", title: "b.txt", relativePath: "b.txt")
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "dirty b\n",
            originalText: "b\n",
            originalMtime: Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: destinationTab.id)
        let source = manager.buffer(worktreeId: "wt", tabId: sourceTab.id, worktreeRoot: root, relativePath: "a.txt")
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))

        #expect(throws: (any Error).self) {
            try source.moveTo(relativePath: "b.txt")
        }

        #expect(source.relativePath == "a.txt")
        #expect(try store.read(worktreeId: "wt", tabId: destinationTab.id)?.content == "dirty b\n")
        #expect(manager.peekBuffer(tabId: destinationTab.id) == nil)
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

    @Test func snapshotDirtyBuffersForQuitWritesEveryTabSharingDirtyBuffer() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let first = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        _ = manager.buffer(worktreeId: "wt", tabId: "t2", worktreeRoot: root, relativePath: "a.txt")
        first.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")

        manager.snapshotDirtyBuffersForQuit()

        #expect(try store.read(worktreeId: "wt", tabId: "t1")?.content == "zx")
        #expect(try store.read(worktreeId: "wt", tabId: "t2")?.content == "zx")
    }

    @Test func editTimeSnapshotWritesEveryTabSharingDirtyBuffer() async throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let buffer = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        _ = manager.buffer(worktreeId: "wt", tabId: "t2", worktreeRoot: root, relativePath: "a.txt")

        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(try store.read(worktreeId: "wt", tabId: "t1")?.content == "zx")
        #expect(try store.read(worktreeId: "wt", tabId: "t2")?.content == "zx")
    }

    @Test func editTimeSnapshotWritesUnloadedTabsSharingDirtyBuffer() async throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let first = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let second = manager.appendEditor(worktreeId: "wt", title: "a copy", relativePath: "a.txt")
        let buffer = manager.buffer(worktreeId: "wt", tabId: first.id, worktreeRoot: root, relativePath: "a.txt")

        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(try store.read(worktreeId: "wt", tabId: first.id)?.content == "zx")
        #expect(try store.read(worktreeId: "wt", tabId: second.id)?.content == "zx")
        #expect(manager.peekBuffer(tabId: second.id) == nil)
    }

    @Test func savingSharedBufferDiscardsEveryTabSnapshot() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let buffer = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        _ = manager.buffer(worktreeId: "wt", tabId: "t2", worktreeRoot: root, relativePath: "a.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")
        manager.snapshotDirtyBuffersForQuit()
        #expect(try store.read(worktreeId: "wt", tabId: "t1") != nil)
        #expect(try store.read(worktreeId: "wt", tabId: "t2") != nil)

        try buffer.save()

        #expect(try store.read(worktreeId: "wt", tabId: "t1") == nil)
        #expect(try store.read(worktreeId: "wt", tabId: "t2") == nil)
    }

    @Test func savingSharedBufferDiscardsUnloadedSiblingSnapshot() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let first = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let second = manager.appendEditor(worktreeId: "wt", title: "a copy", relativePath: "a.txt")
        let stale = EditorBufferStore.Snapshot(
            relativePath: "a.txt",
            content: "stale\n",
            originalText: "x",
            originalMtime: Date(),
            lineEnding: .lf
        )
        try store.write(stale, worktreeId: "wt", tabId: second.id)
        let buffer = manager.buffer(worktreeId: "wt", tabId: first.id, worktreeRoot: root, relativePath: "a.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")

        try buffer.save()

        #expect(try store.read(worktreeId: "wt", tabId: first.id) == nil)
        #expect(try store.read(worktreeId: "wt", tabId: second.id) == nil)
        #expect(manager.peekBuffer(tabId: second.id) == nil)
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
