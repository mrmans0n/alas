import Testing
import Foundation
import Darwin
@testable import Alas

private actor TabsManagerBufferAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor TabsManagerAsyncLoadGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitForWaiterCount(_ count: Int) async {
        while waiters.count < count {
            await Task.yield()
        }
    }
}

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

    @Test func bufferReturnsSameInstanceAcrossCalls() async throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let b1 = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        await b1.awaitLoadForTesting()
        let b2 = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        await b2.awaitLoadForTesting()
        #expect(b1 === b2)
    }

    @Test func asyncSnapshotRestoreRemovesOriginalBufferKey() async throws {
        let root = tempWorktree()
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let gate = TabsManagerBufferAsyncGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let (manager, store, _) = makeManager()
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "dirty b\n",
            originalText: "b\n",
            originalMtime: Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: "t1")

        let restored = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        await gate.open()
        await restored.awaitLoadForTesting()
        let original = manager.buffer(worktreeId: "wt", tabId: "t2", worktreeRoot: root, relativePath: "a.txt")
        await original.awaitLoadForTesting()

        #expect(restored.relativePath == "b.txt")
        #expect(restored.storage.string == "dirty b\n")
        #expect(original !== restored)
        #expect(original.relativePath == "a.txt")
        #expect(original.storage.string == "a\n")
    }

    @Test func asyncSnapshotRestoreRearmsWatcherForRestoredPath() async throws {
        let root = tempWorktree()
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let gate = TabsManagerBufferAsyncGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let (manager, store, _) = makeManager()
        let bURL = root.appendingPathComponent("b.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: bURL.path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "dirty b\n",
            originalText: "b\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: "t1")

        let restored = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        await gate.open()
        await restored.awaitLoadForTesting()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "external b\n".write(to: bURL, atomically: true, encoding: .utf8)
        for _ in 0..<20 where restored.conflict == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(restored.relativePath == "b.txt")
        #expect(restored.conflict == .changedOnDisk)
    }

    @Test func buffersForSamePathShareOneInstanceAcrossTabs() async throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()

        let first = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        await first.awaitLoadForTesting()
        let second = manager.buffer(worktreeId: "wt", tabId: "t2", worktreeRoot: root, relativePath: "a.txt")
        await second.awaitLoadForTesting()
        first.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")

        #expect(first === second)
        #expect(second.storage.string == "zx")
        #expect(manager.dirtyTabIds().sorted() == ["t1", "t2"])
    }

    @Test func closingOneTabForSharedPathKeepsBufferForOtherTab() async throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let first = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        await first.awaitLoadForTesting()
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
        await source.awaitLoadForTesting()
        let destination = manager.buffer(worktreeId: "wt", tabId: "tb", worktreeRoot: root, relativePath: "b.txt")
        await destination.awaitLoadForTesting()
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

    @Test func inAppRenameIntoOpenPathDoesNotReplaceDestinationBuffer() async throws {
        let root = tempWorktree()
        let sourceURL = root.appendingPathComponent("a.txt")
        let destinationURL = root.appendingPathComponent("b.txt")
        try "a\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "b\n".write(to: destinationURL, atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let source = manager.buffer(worktreeId: "wt", tabId: "ta", worktreeRoot: root, relativePath: "a.txt")
        await source.awaitLoadForTesting()
        let destination = manager.buffer(worktreeId: "wt", tabId: "tb", worktreeRoot: root, relativePath: "b.txt")
        await destination.awaitLoadForTesting()
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

    @Test func inAppRenameIntoUnloadedSnapshotPathIsRejected() async throws {
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
        await source.awaitLoadForTesting()
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))

        #expect(throws: (any Error).self) {
            try source.moveTo(relativePath: "b.txt")
        }

        #expect(source.relativePath == "a.txt")
        #expect(try store.read(worktreeId: "wt", tabId: destinationTab.id)?.content == "dirty b\n")
        #expect(manager.peekBuffer(tabId: destinationTab.id) == nil)
    }

    @Test func closingDirtyBufferDiscardsSnapshotAndBuffer() async throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let buffer = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "edited ")
        buffer.snapshotNow()
        manager.discardBuffer(worktreeId: "wt", tabId: "t1")
        #expect(manager.peekBuffer(tabId: "t1") == nil)
        #expect(try store.read(worktreeId: "wt", tabId: "t1") == nil)
    }

    @Test func dirtyTabsReportsAcrossWorktrees() async throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let a = manager.buffer(worktreeId: "wt", tabId: "ta", worktreeRoot: root, relativePath: "a.txt")
        await a.awaitLoadForTesting()
        _ = manager.buffer(worktreeId: "wt", tabId: "tb", worktreeRoot: root, relativePath: "b.txt")
        a.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")
        let dirty = manager.dirtyTabIds()
        #expect(dirty == ["ta"])
    }

    @Test func snapshotDirtyBuffersForQuitWritesOnlyDirty() async throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let a = manager.buffer(worktreeId: "wt", tabId: "ta", worktreeRoot: root, relativePath: "a.txt")
        await a.awaitLoadForTesting()
        _ = manager.buffer(worktreeId: "wt", tabId: "tb", worktreeRoot: root, relativePath: "b.txt")
        a.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")
        manager.snapshotDirtyBuffersForQuit()
        #expect(try store.read(worktreeId: "wt", tabId: "ta") != nil)
        #expect(try store.read(worktreeId: "wt", tabId: "tb") == nil)
    }

    @Test func snapshotDirtyBuffersForQuitWritesEveryTabSharingDirtyBuffer() async throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let first = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        await first.awaitLoadForTesting()
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
        await buffer.awaitLoadForTesting()
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
        await buffer.awaitLoadForTesting()

        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(try store.read(worktreeId: "wt", tabId: first.id)?.content == "zx")
        #expect(try store.read(worktreeId: "wt", tabId: second.id)?.content == "zx")
        #expect(manager.peekBuffer(tabId: second.id) == nil)
    }

    @Test func savingSharedBufferDiscardsEveryTabSnapshot() async throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let buffer = manager.buffer(worktreeId: "wt", tabId: "t1", worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        _ = manager.buffer(worktreeId: "wt", tabId: "t2", worktreeRoot: root, relativePath: "a.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")
        manager.snapshotDirtyBuffersForQuit()
        #expect(try store.read(worktreeId: "wt", tabId: "t1") != nil)
        #expect(try store.read(worktreeId: "wt", tabId: "t2") != nil)

        try buffer.save()

        #expect(try store.read(worktreeId: "wt", tabId: "t1") == nil)
        #expect(try store.read(worktreeId: "wt", tabId: "t2") == nil)
    }

    @Test func savingSharedBufferDiscardsUnloadedSiblingSnapshot() async throws {
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
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")

        try buffer.save()

        #expect(try store.read(worktreeId: "wt", tabId: first.id) == nil)
        #expect(try store.read(worktreeId: "wt", tabId: second.id) == nil)
        #expect(manager.peekBuffer(tabId: second.id) == nil)
    }

    @Test func updateEditorPathPersistsTabMetadata() throws {
        let (manager, _, _) = makeManager()
        let tab = manager.openEditor(
            worktreeId: "wt",
            relativePath: "a.txt",
            revealLine: 2,
            revealCharacter: 0,
            revealEndLine: 4
        )

        #expect(manager.updateEditorPath(worktreeId: "wt", tabId: tab.id, relativePath: "src/b.txt"))

        let updated = manager.tabs(forWorktree: "wt").first { $0.id == tab.id }
        #expect(updated?.title == "b.txt")
        #expect(updated?.relativeFilePath == "src/b.txt")
        if let updated, case .editor(let state) = updated {
            #expect(state.revealLine == nil)
            #expect(state.revealEndLine == nil)
            #expect(state.revealCharacter == nil)
        } else {
            Issue.record("expected editor tab")
        }
    }

    @Test func hasEditorCanExcludeCurrentTab() throws {
        let (manager, _, _) = makeManager()
        let first = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        _ = manager.appendEditor(worktreeId: "wt", title: "b.txt", relativePath: "b.txt")

        #expect(manager.hasEditor(worktreeId: "wt", relativePath: "a.txt"))
        #expect(!manager.hasEditor(worktreeId: "wt", relativePath: "a.txt", excluding: first.id))
        #expect(manager.hasEditor(worktreeId: "wt", relativePath: "b.txt", excluding: first.id))
    }

    @Test func saveAllOnlySavesDirtyBuffersAndReturnsErrors() async throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let a = manager.buffer(worktreeId: "wt", tabId: "ta", worktreeRoot: root, relativePath: "a.txt")
        await a.awaitLoadForTesting()
        _ = manager.buffer(worktreeId: "wt", tabId: "tb", worktreeRoot: root, relativePath: "b.txt")
        a.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")

        let errors = manager.saveAll()

        #expect(errors.isEmpty)
        #expect(a.dirty == false)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "zx")
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "y")
    }

    @Test func saveAllSavesDirtyEditableExternalBuffers() throws {
        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        let externalURL = externalDir.appendingPathComponent("script.sh")
        try "old".write(to: externalURL, atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let buffer = manager.externalBuffer(worktreeId: "wt", tabId: "external-tab", absoluteURL: externalURL, editable: true)
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: buffer.storage.length), with: "new")
        #expect(buffer.dirty)

        let errors = manager.saveAll()

        #expect(errors.isEmpty)
        #expect(buffer.dirty == false)
        #expect(try String(contentsOf: externalURL, encoding: .utf8) == "new")
    }

    @Test func saveAllUnsavedSavesDirtyEditableExternalBuffersForWorktree() throws {
        let root = tempWorktree()
        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        let externalURL = externalDir.appendingPathComponent("script.sh")
        try "old".write(to: externalURL, atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let buffer = manager.externalBuffer(worktreeId: "wt", tabId: "external-tab", absoluteURL: externalURL, editable: true)
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: buffer.storage.length), with: "new")

        let errors = manager.saveAllUnsaved(forWorktree: "wt", root: root)

        #expect(errors.isEmpty)
        #expect(buffer.dirty == false)
        #expect(try String(contentsOf: externalURL, encoding: .utf8) == "new")
    }

    @Test func saveAllUnsavedIgnoresExternalBuffersFromOtherWorktrees() throws {
        let root = tempWorktree()
        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        let externalURL = externalDir.appendingPathComponent("script.sh")
        try "old".write(to: externalURL, atomically: true, encoding: .utf8)
        let (manager, _, _) = makeManager()
        let buffer = manager.externalBuffer(worktreeId: "other-wt", tabId: "external-tab", absoluteURL: externalURL, editable: true)
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: buffer.storage.length), with: "new")

        let errors = manager.saveAllUnsaved(forWorktree: "wt", root: root)

        #expect(errors.isEmpty)
        #expect(buffer.dirty == true)
        #expect(try String(contentsOf: externalURL, encoding: .utf8) == "old")
    }

    @Test func snapshotDirtyBuffersForQuitSnapshotsDirtyEditableExternalBuffers() throws {
        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        let externalURL = externalDir.appendingPathComponent("script.sh")
        try "old".write(to: externalURL, atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let buffer = manager.externalBuffer(worktreeId: "wt", tabId: "external-tab", absoluteURL: externalURL, editable: true)
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: buffer.storage.length), with: "new")

        manager.snapshotDirtyBuffersForQuit()

        #expect(buffer.dirty)
        #expect(try String(contentsOf: externalURL, encoding: .utf8) == "old")
        #expect(try store.read(worktreeId: "wt", tabId: "external-tab")?.content == "new")
    }

    @Test func editableExternalBufferRestoresQuitSnapshot() throws {
        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        let externalURL = externalDir.appendingPathComponent("script.sh")
        try "old".write(to: externalURL, atomically: true, encoding: .utf8)
        let (_, store, _) = makeManager()
        let firstManager = TabsManager(bufferStore: store)
        let first = firstManager.externalBuffer(worktreeId: "wt", tabId: "external-tab", absoluteURL: externalURL, editable: true)
        first.storage.replaceCharacters(in: NSRange(location: 0, length: first.storage.length), with: "new")
        firstManager.snapshotDirtyBuffersForQuit()

        let secondManager = TabsManager(bufferStore: store)
        let restored = secondManager.externalBuffer(worktreeId: "wt", tabId: "external-tab", absoluteURL: externalURL, editable: true)

        #expect(restored.storage.string == "new")
        #expect(restored.dirty)
        #expect(try String(contentsOf: externalURL, encoding: .utf8) == "old")
    }

    @Test func bufferRestoredToSnapshotPathUpdatesTabAndCacheKey() async throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let tab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "edited\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: tab.id)

        let restored = manager.buffer(worktreeId: "wt", tabId: tab.id, worktreeRoot: root, relativePath: "a.txt")
        await restored.awaitLoadForTesting()
        let cachedByRestoredPath = manager.buffer(worktreeId: "wt", tabId: tab.id, worktreeRoot: root, relativePath: "b.txt")
        await cachedByRestoredPath.awaitLoadForTesting()
        let updatedTab = manager.tabs(forWorktree: "wt").first { $0.id == tab.id }

        #expect(restored === cachedByRestoredPath)
        #expect(restored.relativePath == "b.txt")
        #expect(updatedTab?.title == "b.txt")
        #expect(updatedTab?.relativeFilePath == "b.txt")
    }

    @Test func pendingAsyncRestoreToDifferentPathDoesNotShareOldPathBuffer() async throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let restoringTab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let oldPathTab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "edited\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: restoringTab.id)
        let gate = TabsManagerAsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }

        let restoringBuffer = manager.buffer(worktreeId: "wt", tabId: restoringTab.id, worktreeRoot: root, relativePath: "a.txt")
        let oldPathBuffer = manager.buffer(worktreeId: "wt", tabId: oldPathTab.id, worktreeRoot: root, relativePath: "a.txt")
        await gate.open()
        await restoringBuffer.awaitLoadForTesting()
        await oldPathBuffer.awaitLoadForTesting()

        #expect(restoringBuffer !== oldPathBuffer)
        #expect(restoringBuffer.relativePath == "b.txt")
        #expect(oldPathBuffer.relativePath == "a.txt")
    }

    @Test func pendingAsyncRestoreToDifferentPathReusesSameTabBuffer() async throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let tab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "edited\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: tab.id)
        let gate = TabsManagerAsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }

        let first = manager.buffer(worktreeId: "wt", tabId: tab.id, worktreeRoot: root, relativePath: "a.txt")
        let second = manager.buffer(worktreeId: "wt", tabId: tab.id, worktreeRoot: root, relativePath: "a.txt")
        await gate.open()
        await first.awaitLoadForTesting()
        await second.awaitLoadForTesting()

        #expect(first === second)
        #expect(first.relativePath == "b.txt")
    }

    @Test func pendingAsyncRestoreWinsOverOldPathCacheForSameTab() async throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let restoringTab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let otherTab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "restored\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: restoringTab.id)
        let gate = TabsManagerAsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }

        let pending = manager.buffer(worktreeId: "wt", tabId: restoringTab.id, worktreeRoot: root, relativePath: "a.txt")
        let oldPath = manager.buffer(worktreeId: "wt", tabId: otherTab.id, worktreeRoot: root, relativePath: "a.txt")
        let again = manager.buffer(worktreeId: "wt", tabId: restoringTab.id, worktreeRoot: root, relativePath: "a.txt")
        await gate.open()
        await pending.awaitLoadForTesting()
        await oldPath.awaitLoadForTesting()

        #expect(again === pending)
        #expect(oldPath !== pending)
        #expect(pending.relativePath == "b.txt")
        #expect(oldPath.relativePath == "a.txt")
    }

    @Test func asyncRestoreDoesNotOverwriteBufferOpenedAtTargetPath() async throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let restoringTab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let targetTab = manager.appendEditor(worktreeId: "wt", title: "b.txt", relativePath: "b.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "restored\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: restoringTab.id)
        let gate = TabsManagerAsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }

        let pending = manager.buffer(worktreeId: "wt", tabId: restoringTab.id, worktreeRoot: root, relativePath: "a.txt")
        await gate.waitForWaiterCount(1)
        let target = manager.buffer(worktreeId: "wt", tabId: targetTab.id, worktreeRoot: root, relativePath: "b.txt")
        await gate.open()
        await pending.awaitLoadForTesting()
        await target.awaitLoadForTesting()

        #expect(manager.peekBuffer(tabId: targetTab.id) === target)
        #expect(target.relativePath == "b.txt")
        #expect(target.storage.string == "base\n")
    }

    @Test func pendingAsyncRestoreDirtyBufferIsVisibleBeforeRestoreFinishes() async throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let tab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "restored\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: tab.id)
        let gate = TabsManagerAsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }

        let pending = manager.buffer(worktreeId: "wt", tabId: tab.id, worktreeRoot: root, relativePath: "a.txt")
        pending.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "typed")

        #expect(manager.peekBuffer(tabId: tab.id) === pending)
        #expect(manager.dirtyTabIds().contains(tab.id))

        await gate.open()
        await pending.awaitLoadForTesting()
    }

    @Test func pendingAsyncRestoreReplaysPreloadEditAndDiscardsSnapshotAfterSave() async throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let tab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "restored\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: tab.id)
        let gate = TabsManagerAsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }

        let pending = manager.buffer(worktreeId: "wt", tabId: tab.id, worktreeRoot: root, relativePath: "a.txt")
        pending.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "typed")

        await gate.open()
        await pending.awaitLoadForTesting()
        #expect(manager.peekBuffer(tabId: tab.id) === pending)
        #expect(pending.relativePath == "b.txt")
        #expect(pending.storage.string == "typedrestored\n")

        pending.resolveConflictKeepingMine()
        try pending.save()

        #expect(try store.read(worktreeId: "wt", tabId: tab.id) == nil)
    }

    @Test func preloadEditedRestoredBufferMoveDoesNotMoveOldPathTabs() async throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let restoringTab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let oldPathTab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "restored\n",
            originalText: "base\n",
            originalMtime: Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: restoringTab.id)
        let gate = TabsManagerAsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }

        let restoring = manager.buffer(
            worktreeId: "wt",
            tabId: restoringTab.id,
            worktreeRoot: root,
            relativePath: "a.txt"
        )
        restoring.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "typed ")
        let oldPath = manager.buffer(
            worktreeId: "wt",
            tabId: oldPathTab.id,
            worktreeRoot: root,
            relativePath: "a.txt"
        )
        await gate.open()
        await restoring.awaitLoadForTesting()
        await oldPath.awaitLoadForTesting()
        restoring.resolveConflictKeepingMine()

        try restoring.saveAs(relativePath: "c.txt")

        let tabs = manager.tabs(forWorktree: "wt")
        #expect(restoring !== oldPath)
        #expect(manager.peekBuffer(tabId: restoringTab.id) === restoring)
        #expect(manager.peekBuffer(tabId: oldPathTab.id) === oldPath)
        #expect(tabs.first { $0.id == restoringTab.id }?.relativeFilePath == "c.txt")
        #expect(tabs.first { $0.id == oldPathTab.id }?.relativeFilePath == "a.txt")
    }

    @Test func bufferRestoreChecksConflictAfterAsyncSnapshotRestore() async throws {
        let root = tempWorktree()
        try "base\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let tab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("a.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "a.txt",
            content: "edited\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: tab.id)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "external\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let restored = manager.buffer(worktreeId: "wt", tabId: tab.id, worktreeRoot: root, relativePath: "a.txt")
        await restored.awaitLoadForTesting()

        #expect(restored.storage.string == "edited\n")
        #expect(restored.conflict == .changedOnDisk)
    }

    @Test func bufferRestoreToOpenTargetPathReusesExistingOriginalPathBuffer() async throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let sourceTab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let existingTab = manager.appendEditor(worktreeId: "wt", title: "c.txt", relativePath: "c.txt")
        let targetTab = manager.appendEditor(worktreeId: "wt", title: "b.txt", relativePath: "b.txt")
        // Create a live buffer at the original path from another tab
        let existing = manager.buffer(worktreeId: "wt", tabId: existingTab.id, worktreeRoot: root, relativePath: "a.txt")
        await existing.awaitLoadForTesting()
        existing.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "shared ")
        // Set up a dirty snapshot for sourceTab that would restore to b.txt
        let target = manager.buffer(worktreeId: "wt", tabId: targetTab.id, worktreeRoot: root, relativePath: "b.txt")
        await target.awaitLoadForTesting()
        target.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "target ")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "restored\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: sourceTab.id)

        let restored = manager.buffer(worktreeId: "wt", tabId: sourceTab.id, worktreeRoot: root, relativePath: "a.txt")
        await restored.awaitLoadForTesting()
        let updatedTab = manager.tabs(forWorktree: "wt").first { $0.id == sourceTab.id }

        #expect(restored === existing)
        #expect(restored.relativePath == "a.txt")
        #expect(existing.storage.string == "shared old\n")
        #expect(target.storage.string == "target base\n")
        #expect(manager.peekBuffer(tabId: targetTab.id) === target)
        #expect(updatedTab?.relativeFilePath == "a.txt")
        #expect(try store.read(worktreeId: "wt", tabId: sourceTab.id) == nil)
    }

    @Test func bufferRestoreToOpenTargetPathIsDiscarded() async throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let sourceTab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let targetTab = manager.appendEditor(worktreeId: "wt", title: "b.txt", relativePath: "b.txt")
        let target = manager.buffer(worktreeId: "wt", tabId: targetTab.id, worktreeRoot: root, relativePath: "b.txt")
        await target.awaitLoadForTesting()
        target.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "target ")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "restored\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: sourceTab.id)

        let restored = manager.buffer(worktreeId: "wt", tabId: sourceTab.id, worktreeRoot: root, relativePath: "a.txt")
        await restored.awaitLoadForTesting()
        let updatedTab = manager.tabs(forWorktree: "wt").first { $0.id == sourceTab.id }

        #expect(restored !== target)
        #expect(restored.relativePath == "a.txt")
        #expect(target.storage.string == "target base\n")
        #expect(manager.peekBuffer(tabId: targetTab.id) === target)
        #expect(updatedTab?.relativeFilePath == "a.txt")
        #expect(try store.read(worktreeId: "wt", tabId: sourceTab.id) == nil)
    }

    @Test func bufferRestoreToCleanUnloadedTargetPathIsDiscarded() async throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let sourceTab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let targetTab = manager.appendEditor(worktreeId: "wt", title: "b.txt", relativePath: "b.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "restored\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: sourceTab.id)

        let restored = manager.buffer(worktreeId: "wt", tabId: sourceTab.id, worktreeRoot: root, relativePath: "a.txt")
        await restored.awaitLoadForTesting()
        let target = manager.buffer(worktreeId: "wt", tabId: targetTab.id, worktreeRoot: root, relativePath: "b.txt")
        await target.awaitLoadForTesting()
        let updatedTab = manager.tabs(forWorktree: "wt").first { $0.id == sourceTab.id }

        #expect(restored !== target)
        #expect(restored.relativePath == "a.txt")
        #expect(target.relativePath == "b.txt")
        #expect(updatedTab?.relativeFilePath == "a.txt")
        #expect(try store.read(worktreeId: "wt", tabId: sourceTab.id) == nil)
    }

    @Test func bufferRestoreAllowsTargetTabSnapshotThatMovesAway() async throws {
        let root = tempWorktree()
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "c\n".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let first = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let second = manager.appendEditor(worktreeId: "wt", title: "b.txt", relativePath: "b.txt")
        let bAttrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let cAttrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("c.txt").path)
        try store.write(EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "edited b\n",
            originalText: "b\n",
            originalMtime: (bAttrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        ), worktreeId: "wt", tabId: first.id)
        try store.write(EditorBufferStore.Snapshot(
            relativePath: "c.txt",
            content: "edited c\n",
            originalText: "c\n",
            originalMtime: (cAttrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        ), worktreeId: "wt", tabId: second.id)

        let firstBuffer = manager.buffer(worktreeId: "wt", tabId: first.id, worktreeRoot: root, relativePath: "a.txt")
        await firstBuffer.awaitLoadForTesting()
        let secondBuffer = manager.buffer(worktreeId: "wt", tabId: second.id, worktreeRoot: root, relativePath: "b.txt")
        await secondBuffer.awaitLoadForTesting()

        #expect(firstBuffer.relativePath == "b.txt")
        #expect(secondBuffer.relativePath == "c.txt")
        #expect(manager.tabs(forWorktree: "wt").first { $0.id == first.id }?.relativeFilePath == "b.txt")
        #expect(manager.tabs(forWorktree: "wt").first { $0.id == second.id }?.relativeFilePath == "c.txt")
    }

    @Test func saveAllSavesUnloadedDirtySnapshots() throws {
        let root = tempWorktree()
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("a.txt").path)
        let (manager, store, _) = makeManager()
        let tab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "a.txt",
            content: "edited\n",
            originalText: "x",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: tab.id)

        let errors = manager.saveAll(worktreeRoots: ["wt": root])

        #expect(errors.isEmpty)
        #expect(manager.peekBuffer(tabId: tab.id) == nil)
        #expect(try store.read(worktreeId: "wt", tabId: tab.id) == nil)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "edited\n")
    }

    @Test func saveAllUpdatesTabWhenUnloadedSnapshotRestoresMovedPath() throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let tab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "edited\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: tab.id)

        let errors = manager.saveAll(worktreeRoots: ["wt": root])
        let updatedTab = manager.tabs(forWorktree: "wt").first { $0.id == tab.id }

        #expect(errors.isEmpty)
        #expect(updatedTab?.title == "b.txt")
        #expect(updatedTab?.relativeFilePath == "b.txt")
        #expect(try store.read(worktreeId: "wt", tabId: tab.id) == nil)
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "edited\n")
    }

    @Test func saveAllSkipsUnloadedSnapshotThatWouldReplaceLiveTargetBuffer() async throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let sourceTab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let targetTab = manager.appendEditor(worktreeId: "wt", title: "b.txt", relativePath: "b.txt")
        let target = manager.buffer(worktreeId: "wt", tabId: targetTab.id, worktreeRoot: root, relativePath: "b.txt")
        await target.awaitLoadForTesting()
        target.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "target ")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "restored\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: sourceTab.id)

        let errors = manager.saveAll(worktreeRoots: ["wt": root])
        let updatedTab = manager.tabs(forWorktree: "wt").first { $0.id == sourceTab.id }

        #expect(errors.isEmpty)
        #expect(updatedTab?.relativeFilePath == "a.txt")
        #expect(target.storage.string == "target base\n")
        #expect(manager.peekBuffer(tabId: targetTab.id) === target)
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "target base\n")
        #expect(try store.read(worktreeId: "wt", tabId: sourceTab.id) == nil)
    }

    @Test func saveAllUnsavedUpdatesTabWhenUnloadedSnapshotRestoresMovedPath() throws {
        let root = tempWorktree()
        try "old\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "base\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let (manager, store, _) = makeManager()
        let tab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("b.txt").path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.txt",
            content: "edited\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: tab.id)

        let errors = manager.saveAllUnsaved(forWorktree: "wt", root: root)
        let updatedTab = manager.tabs(forWorktree: "wt").first { $0.id == tab.id }

        #expect(errors.isEmpty)
        #expect(updatedTab?.title == "b.txt")
        #expect(updatedTab?.relativeFilePath == "b.txt")
        #expect(try store.read(worktreeId: "wt", tabId: tab.id) == nil)
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "edited\n")
    }

    @Test func saveAllUnsavedBlocksWhileLiveBufferHasPendingSnapshotRestore() async throws {
        let root = tempWorktree()
        let fileURL = root.appendingPathComponent("a.txt")
        try "base\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let gate = TabsManagerAsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let (manager, store, _) = makeManager()
        let tab = manager.appendEditor(worktreeId: "wt", title: "a.txt", relativePath: "a.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "a.txt",
            content: "restored\n",
            originalText: "base\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: tab.id)

        let buffer = manager.buffer(
            worktreeId: "wt",
            tabId: tab.id,
            worktreeRoot: root,
            relativePath: "a.txt"
        )
        await gate.waitForWaiterCount(1)

        #expect(manager.tabIdsWithUnsavedChanges(forWorktree: "wt") == [tab.id])
        let pendingErrors = manager.saveAllUnsaved(forWorktree: "wt", root: root)
        #expect(pendingErrors.map(\.tabId) == [tab.id])
        #expect(try store.read(worktreeId: "wt", tabId: tab.id) == snapshot)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "base\n")

        await gate.open()
        await buffer.awaitLoadForTesting()

        let loadedErrors = manager.saveAllUnsaved(forWorktree: "wt", root: root)
        #expect(loadedErrors.isEmpty)
        #expect(try store.read(worktreeId: "wt", tabId: tab.id) == nil)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "restored\n")
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

    @Test func externalBufferIsReleasedWhenTabIsClosed() async throws {
        let (manager, store, _) = makeManager()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-tab-discard-\(UUID().uuidString).h")
        try "// header\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let tabId = "ext-tab"
        let a = manager.externalBuffer(worktreeId: "wt", tabId: tabId, absoluteURL: url)
        await a.awaitLoadForTesting()
        manager.discardBuffer(worktreeId: "wt", tabId: tabId)
        // After discard the store must have evicted the entry; requesting the
        // buffer again should return a new (distinct) instance.
        let b = store.externalBuffer(worktreeId: "wt", absoluteURL: url)
        await b.awaitLoadForTesting()
        #expect(a !== b)
    }

    /// Calling `externalBuffer` for the same `tabId` twice (simulating a tab
    /// switch back) must return the SAME cached buffer instance — proving the
    /// cache-hit path is exercised and that a second LSP open would be guarded
    /// by the `openedExternalDocs` set.
    @Test func externalBufferCacheHitReturnsSameInstance() async throws {
        let (manager, _, _) = makeManager()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-cache-hit-\(UUID().uuidString).h")
        try "// header\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let root = FileManager.default.temporaryDirectory
        let tabId = "ext-cache-tab"
        let a = manager.externalBuffer(
            worktreeId: "wt", tabId: tabId, absoluteURL: url,
            worktreeRoot: root, originatingFileURL: nil, language: "c"
        )
        await a.awaitLoadForTesting()
        // Simulates the view being dismantled and remounted (tab switch away
        // and back). The second call must return the same instance and must
        // NOT attempt a second openExternalDocument.
        let b = manager.externalBuffer(
            worktreeId: "wt", tabId: tabId, absoluteURL: url,
            worktreeRoot: root, originatingFileURL: nil, language: "c"
        )
        await b.awaitLoadForTesting()
        #expect(a === b)
    }
}
