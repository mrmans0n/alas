// AlasTests/EditorBufferTests.swift
import Testing
import Foundation
import AppKit
@testable import Alas

@MainActor
@Suite(.serialized)
struct EditorBufferTests {
    private func tempWorktree() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-buffer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(_ root: URL, _ rel: String, _ contents: String, perms: Int = 0o644) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
        return url
    }

    @Test func remoteConflictChecksCoalesceAnOverlappingRequest() {
        var checks = RemoteConflictCheckCoalescer()

        let initialCheck = checks.beginOrMarkPending()
        let overlappingCheck = checks.beginOrMarkPending()
        let shouldRepeat = checks.finishCheck()
        let isDrained = !checks.finishCheck()
        let nextCheck = checks.beginOrMarkPending()

        #expect(initialCheck)
        #expect(!overlappingCheck)
        #expect(shouldRepeat)
        #expect(isDrained)
        #expect(nextCheck)
    }

    @Test func remoteHelperFileWatchMatchesCanonicalEventRootByRelativePath() {
        let matcher = RemoteHelperFileWatchMatcher(
            targetURL: URL(fileURLWithPath: "/symlinked/repo/Sources/App.swift"),
            watchedRootURL: URL(fileURLWithPath: "/symlinked/repo/Sources")
        )
        let event = RemoteHelperWatchEvent(
            subscriptionId: "sub",
            root: "/real/repo/Sources",
            kind: .files,
            paths: ["/real/repo/Sources/App.swift"]
        )

        #expect(matcher.matches(event: event))
    }

    @Test func remoteHelperFileWatchIgnoresSiblingUnderCanonicalEventRoot() {
        let matcher = RemoteHelperFileWatchMatcher(
            targetURL: URL(fileURLWithPath: "/symlinked/repo/Sources/App.swift"),
            watchedRootURL: URL(fileURLWithPath: "/symlinked/repo/Sources")
        )
        let event = RemoteHelperWatchEvent(
            subscriptionId: "sub",
            root: "/real/repo/Sources",
            kind: .files,
            paths: ["/real/repo/Sources/Other.swift"]
        )

        #expect(!matcher.matches(event: event))
    }

    @Test func remoteHelperFileWatchMatchesSameAbsolutePath() {
        let matcher = RemoteHelperFileWatchMatcher(
            targetURL: URL(fileURLWithPath: "/repo/Sources/App.swift"),
            watchedRootURL: URL(fileURLWithPath: "/repo/Sources")
        )
        let event = RemoteHelperWatchEvent(
            subscriptionId: "sub",
            root: "/repo/Sources",
            kind: .files,
            paths: ["/repo/Sources/App.swift"]
        )

        #expect(matcher.matches(event: event))
    }

    /// Regression: remote file content was applied to storage without
    /// notifying edit observers, so `CodeEditorCoordinator` never re-applied
    /// the theme's base style (font, foreground color) or ran syntax
    /// highlighting. Editors in SSH repos therefore showed the wrong colors.
    @Test func remoteLoadNotifiesObserversWhenContentArrives() async throws {
        let root = tempWorktree()
        RemoteHostRegistry.shared.register(root: root.path, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root.path) }

        let expectedContent = "print(\"hello\")\n"
        EditorBuffer.remoteReadResultForTesting = { _, _ in
            .file(data: Data(expectedContent.utf8), mtime: Date(timeIntervalSince1970: 1_000))
        }
        defer { EditorBuffer.remoteReadResultForTesting = nil }

        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "main.py")
        defer { buffer.close(persistDirtySnapshot: false) }

        var notifications = 0
        let token = buffer.onTextEdit { _ in notifications += 1 }
        defer { buffer.removeOnEdit(token) }

        let deadline = Date(timeIntervalSinceNow: 2)
        while buffer.storage.string != expectedContent && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(buffer.storage.string == expectedContent)
        #expect(buffer.originalText == expectedContent)
        #expect(buffer.loadKind == .loaded)
        #expect(notifications > 0, "Remote content arrival must notify edit observers so the coordinator can re-apply editor styling")
    }

    @Test func coldLoadCapturesContentMtimeAndPerms() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "hello\nworld\n", perms: 0o644)
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        #expect(buffer.storage.string == "hello\nworld\n")
        #expect(buffer.originalText == "hello\nworld\n")
        #expect(buffer.lineEnding == .lf)
        #expect(buffer.dirty == false)
        #expect(buffer.permissions == 0o644)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let onDisk = attrs[.modificationDate] as? Date
        #expect(buffer.originalMtime == onDisk)
    }

    @Test func coldLoadDetectsCRLF() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "win.txt", "a\r\nb\r\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "win.txt")
        await buffer.awaitLoadForTesting()
        #expect(buffer.lineEnding == .crlf)
        // We canonicalize to LF in memory; save normalizes back.
        #expect(buffer.storage.string == "a\nb\n")
        #expect(buffer.originalText == "a\nb\n")
    }

    @Test func coldLoadOnMissingFileReadsAsErrorAndIsReadOnly() async {
        let root = tempWorktree()
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "missing.txt")
        await buffer.awaitLoadForTesting()
        #expect(buffer.storage.string == "(unable to read file)")
        #expect(buffer.readOnly == true)
        #expect(buffer.dirty == false)
    }

    @Test func coldLoadOnNonUTF8FileIsReadOnlyWithClearMessage() async throws {
        let root = tempWorktree()
        let url = root.appendingPathComponent("latin1.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: url)

        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "latin1.txt")
        await buffer.awaitLoadForTesting()

        #expect(buffer.storage.string == "(read-only: file is not valid UTF-8)")
        #expect(buffer.readOnly == true)
        #expect(buffer.dirty == false)
    }

    @Test func coldLoadResolvesSymlinkToTargetContents() async throws {
        let root = tempWorktree()
        let target = root.appendingPathComponent("real.txt")
        try "hello from symlink target\n".write(to: target, atomically: true, encoding: .utf8)

        let linkURL = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)

        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "link.txt")
        await buffer.awaitLoadForTesting()

        #expect(buffer.storage.string == "hello from symlink target\n")
        #expect(buffer.readOnly == true)
        #expect(buffer.dirty == false)
    }

    @Test func saveWritesContentAndClearsDirty() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "hello\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        #expect(buffer.dirty == true)
        try buffer.save()
        #expect(buffer.dirty == false)
        let onDisk = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(onDisk == "HELLO\n")
        #expect(buffer.originalText == "HELLO\n")
    }

    @Test func saveBeforeInitialLoadFinishesDoesNotOverwriteFile() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "hello\n")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer {
            EditorBuffer.loadGateForTesting = nil
            EditorBuffer.loadResultForTesting = nil
        }

        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")

        try buffer.save()
        let onDiskBeforeLoad = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        await gate.open()
        await buffer.awaitLoadForTesting()

        #expect(onDiskBeforeLoad == "hello\n")
        #expect(buffer.storage.string == "hello\n")
        #expect(buffer.dirty == false)
    }

    @Test func saveDirtyBufferBeforeInitialLoadFinishesThrows() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "hello\n")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "typed")

        #expect(throws: (any Error).self) {
            try buffer.save()
        }

        await gate.open()
        await buffer.awaitLoadForTesting()
    }

    @Test func saveAsBeforeInitialLoadFinishesThrows() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "hello\n")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")

        #expect(throws: EditorBuffer.SaveError.self) {
            try buffer.saveAs(relativePath: "copy.txt")
        }
        let copyURL = root.appendingPathComponent("copy.txt")

        await gate.open()
        await buffer.awaitLoadForTesting()

        #expect(FileManager.default.fileExists(atPath: copyURL.path) == false)
        #expect(buffer.relativePath == "a.txt")
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "hello\n")
    }

    @Test func moveToBeforeInitialLoadFinishesThrows() async throws {
        let root = tempWorktree()
        let originalURL = try writeFile(root, "a.txt", "hello\n")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")

        #expect(throws: EditorBuffer.SaveError.self) {
            try buffer.moveTo(relativePath: "moved.txt")
        }
        let movedURL = root.appendingPathComponent("moved.txt")

        await gate.open()
        await buffer.awaitLoadForTesting()

        #expect(FileManager.default.fileExists(atPath: movedURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: originalURL.path))
        #expect(buffer.relativePath == "a.txt")
        #expect(try String(contentsOf: originalURL, encoding: .utf8) == "hello\n")
    }

    @Test func saveAsWritesNewPathAndLeavesOriginalFile() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "hello\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")

        try buffer.saveAs(relativePath: "nested/b.txt")

        #expect(buffer.relativePath == "nested/b.txt")
        #expect(buffer.dirty == false)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "hello\n")
        #expect(try String(contentsOf: root.appendingPathComponent("nested/b.txt"), encoding: .utf8) == "HELLO\n")
    }

    @Test func moveToRenamesFileAndKeepsDirtyEdits() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "hello\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")

        try buffer.moveTo(relativePath: "b.txt")

        #expect(buffer.relativePath == "b.txt")
        #expect(buffer.dirty == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "hello\n")
    }

    @Test func moveToRewritesSnapshotWhenBufferStaysDirty() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "hello\n")
        let store = EditorBufferStore(rootOverride: tempWorktree())
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt", store: store, worktreeId: "wt", tabId: "t")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        buffer.snapshotNow()

        try buffer.moveTo(relativePath: "b.txt")

        let snapshot = try store.read(worktreeId: "wt", tabId: "t")
        #expect(snapshot?.relativePath == "b.txt")
        #expect(snapshot?.content == "HELLO\n")
        #expect(buffer.dirty == true)
    }

    @Test func restoreAfterDirtyMoveUsesSnapshotPath() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "hello\n")
        let store = EditorBufferStore(rootOverride: tempWorktree())
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt", store: store, worktreeId: "wt", tabId: "t")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")

        try buffer.moveTo(relativePath: "b.txt")

        let restored = EditorBuffer(worktreeRoot: root, relativePath: "a.txt", store: store, worktreeId: "wt", tabId: "t")
        await restored.awaitLoadForTesting()
        #expect(restored.relativePath == "b.txt")
        try restored.save()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "HELLO\n")
    }

    @Test func restoreAfterDirtyMoveRefreshesTargetPermissions() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.sh", "#!/bin/sh\necho old\n", perms: 0o644)
        let target = try writeFile(root, "b.sh", "#!/bin/sh\necho old\n", perms: 0o755)
        let store = EditorBufferStore(rootOverride: tempWorktree())
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "b.sh",
            content: "#!/bin/sh\necho new\n",
            originalText: "#!/bin/sh\necho old\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: "t")

        let restored = EditorBuffer(worktreeRoot: root, relativePath: "a.sh", store: store, worktreeId: "wt", tabId: "t")
        await restored.awaitLoadForTesting()
        try restored.save()

        let savedAttrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let perms = (savedAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(restored.relativePath == "b.sh")
        #expect(perms == 0o755)
    }

    @Test func moveToAllowsCaseOnlyRename() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "case.txt", "hello\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "case.txt")
        await buffer.awaitLoadForTesting()

        try buffer.moveTo(relativePath: "Case.txt")

        #expect(buffer.relativePath == "Case.txt")
        #expect(try String(contentsOf: root.appendingPathComponent("Case.txt"), encoding: .utf8) == "hello\n")
    }

    @Test func moveToRejectsExistingDifferentFile() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "a\n")
        _ = try writeFile(root, "b.txt", "b\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()

        #expect(throws: (any Error).self) {
            try buffer.moveTo(relativePath: "b.txt")
        }

        #expect(buffer.relativePath == "a.txt")
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "a\n")
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "b\n")
    }

    @Test func saveCRLFFilePreservesCRLFOnDisk() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "win.txt", "a\r\nb\r\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "win.txt")
        await buffer.awaitLoadForTesting()
        // In-memory storage is canonical LF; user appends a line.
        buffer.storage.replaceCharacters(in: NSRange(location: buffer.storage.length, length: 0), with: "c\n")
        try buffer.save()
        let onDisk = try Data(contentsOf: root.appendingPathComponent("win.txt"))
        #expect(onDisk == Data("a\r\nb\r\nc\r\n".utf8))
        #expect(buffer.dirty == false)
    }

    @Test func savePreservesPosixPermissions() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "exe.sh", "#!/bin/sh\necho hi\n", perms: 0o755)
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "exe.sh")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# touched\n")
        try buffer.save()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o755)
    }

    @Test func saveOnReadOnlyDirThrowsAndKeepsBufferDirty() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "x")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "more\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        }
        #expect(throws: (any Error).self) { try buffer.save() }
        #expect(buffer.dirty == true)
        #expect(buffer.originalText == "x")
    }

    @Test func saveRecordingErrorStoresThrownSaveFailure() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "x")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "more\n")
        try FileManager.default.removeItem(at: root)
        #expect(throws: (any Error).self) { try buffer.saveRecordingError() }
        #expect(buffer.lastSaveError?.isEmpty == false)
        #expect(buffer.dirty == true)
    }

    @Test func saveUpdatesMtime() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "x")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        let oldMtime = buffer.originalMtime
        // Sleep a tiny bit so HFS/APFS-second-resolution mtimes actually advance.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "y")
        try buffer.save()
        #expect(buffer.originalMtime > oldMtime)
    }

    @Test func editingFlipsDirtyAndFiresObserver() async {
        let root = tempWorktree()
        _ = try? writeFile(root, "a.txt", "hello\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        var fired = 0
        let token = buffer.onEdit { fired += 1 }
        defer { buffer.removeOnEdit(token) }
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        #expect(buffer.dirty == true)
        #expect(fired == 1)
    }

    @Test func editBeforeAsyncLoadFinishesIsPreserved() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "disk\n")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }

        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "typed")
        await gate.open()
        await buffer.awaitLoadForTesting()

        #expect(buffer.storage.string == "typeddisk\n")
        #expect(buffer.dirty == true)
    }

    @Test func editBeforeAsyncLoadFinishesKeepsDiskBaselineAndSaveBlocked() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "disk\n")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "typed")

        await gate.open()
        await buffer.awaitLoadForTesting()
        let url = root.appendingPathComponent("a.txt")
        try "external\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)

        #expect(throws: (any Error).self) {
            try buffer.save()
        }

        #expect(try String(contentsOf: url, encoding: .utf8) == "external\n")
    }

    @Test func editBeforeAsyncLoadFinishesCannotSavePartialTextAfterLoad() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "disk\n")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "typed")

        await gate.open()
        await buffer.awaitLoadForTesting()

        #expect(throws: (any Error).self) {
            try buffer.save()
        }

        #expect(try String(contentsOf: url, encoding: .utf8) == "disk\n")
        #expect(buffer.conflict == .changedOnDisk)

        buffer.resolveConflictKeepingMine()
        try buffer.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "typeddisk\n")
    }

    @Test func editBeforeAsyncSymlinkLoadPreservesReadOnlyState() async throws {
        let root = tempWorktree()
        let target = try writeFile(root, "target.txt", "disk\n")
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "link.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "typed")

        await gate.open()
        await buffer.awaitLoadForTesting()

        #expect(buffer.readOnly == true)
        buffer.resolveConflictKeepingMine()
        try buffer.save()
        #expect(try String(contentsOf: target, encoding: .utf8) == "disk\n")
    }

    @Test func editBeforeAsyncLoadFinishesReplaysOntoSnapshotRestore() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "disk\n")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let store = EditorBufferStore(rootOverride: tempWorktree())
        let snapshot = EditorBufferStore.Snapshot(
            relativePath: "a.txt",
            content: "snapshot\n",
            originalText: "disk\n",
            originalMtime: (attrs[.modificationDate] as? Date) ?? Date(),
            lineEnding: .lf
        )
        try store.write(snapshot, worktreeId: "wt", tabId: "t")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt", store: store, worktreeId: "wt", tabId: "t")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "typed")

        await gate.open()
        await buffer.awaitLoadForTesting()

        #expect(buffer.storage.string == "typedsnapshot\n")
        #expect(buffer.originalText == "disk\n")
        #expect(buffer.conflict == .changedOnDisk)
        #expect(try store.read(worktreeId: "wt", tabId: "t") == snapshot)
    }

    @Test func watcherEventDuringInitialLoadTriggersReloadAfterLoadFinishes() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "old\n")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        final class StaleReadOnce: @unchecked Sendable { var used = false }
        let staleRead = StaleReadOnce()
        EditorBuffer.loadResultForTesting = { _ in
            if staleRead.used { return nil }
            staleRead.used = true
            return "old\n"
        }
        defer {
            EditorBuffer.loadGateForTesting = nil
            EditorBuffer.loadResultForTesting = nil
        }
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")

        buffer.handleWatcherEventForTesting()
        try "new\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await gate.open()
        await buffer.awaitLoadForTesting()
        await buffer.awaitLoadForTesting()

        #expect(buffer.storage.string == "new\n")
    }

    @Test func watcherEventDuringPreservedInitialEditKeepsUserTextAndRaisesConflict() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "old\n")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        EditorBuffer.loadResultForTesting = { _ in "old\n" }
        defer {
            EditorBuffer.loadGateForTesting = nil
            EditorBuffer.loadResultForTesting = nil
        }
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "typed")

        try "new\n".write(to: url, atomically: true, encoding: .utf8)
        buffer.handleWatcherEventForTesting()
        await gate.open()
        await buffer.awaitLoadForTesting()

        #expect(buffer.storage.string == "typedold\n")
        #expect(buffer.conflict == .changedOnDisk)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new\n")
    }

    @Test func closeBeforeAsyncLoadFinishesDoesNotOpenLSPDocument() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "main.swift", "print(1)\n")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let store = EditorBufferStore(rootOverride: tempWorktree())
        let lsp = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: "/usr/bin/true",
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ]), makeClient: { _, _, _, language, rootURI in
            LSPClient(transport: FakeTransport(), language: language, rootURI: rootURI)
        })

        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "main.swift", store: store, worktreeId: "wt", tabId: "t", lsp: lsp)
        buffer.close(persistDirtySnapshot: false)
        await gate.open()
        await buffer.awaitLoadForTesting()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(lsp.documentStatus(forFile: url, worktreeRoot: root) == .none)
    }

    @Test func reopenBeforeAsyncLoadFinishesOpensLSPOnceWithLoadedText() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "main.swift", "print(1)\n")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let store = EditorBufferStore(rootOverride: tempWorktree())
        let transport = FakeTransport()
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}"#)
            }
        }
        let lsp = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: "/usr/bin/true",
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ]), makeClient: { _, _, _, language, rootURI in
            LSPClient(transport: transport, language: language, rootURI: rootURI)
        })
        let buffer = EditorBuffer(
            worktreeRoot: root,
            relativePath: "main.swift",
            store: store,
            worktreeId: "wt",
            tabId: "t",
            lsp: lsp
        )

        buffer.reopenLSPDocument()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!transport.sent.contains { $0.contains(#""method":"textDocument/didOpen""#) })

        await gate.open()
        await buffer.awaitLoadForTesting()
        for _ in 0..<20 where !transport.sent.contains(where: { $0.contains(#""method":"textDocument/didOpen""#) }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let didOpen = transport.sent.filter { $0.contains(#""method":"textDocument/didOpen""#) }
        #expect(didOpen.count == 1)
        #expect(didOpen.first?.contains(#""text":"print(1)\n""#) == true)
        buffer.close(persistDirtySnapshot: false)
        transport.finish()
    }

    @Test func reopenRetriesAfterInitialLSPServerWasUnavailable() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "main.swift", "print(1)\n")
        let store = EditorBufferStore(rootOverride: tempWorktree())
        let transport = FakeTransport()
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}"#)
            }
        }
        let unavailable = LanguageServerConfig(
            language: "swift",
            extensions: ["swift"],
            command: root.appendingPathComponent("missing-server").path,
            args: [],
            env: [:],
            rootMarkers: [],
            enabled: true
        )
        let available = LanguageServerConfig(
            language: "swift",
            extensions: ["swift"],
            command: "/usr/bin/true",
            args: [],
            env: [:],
            rootMarkers: [],
            enabled: true
        )
        let lsp = WorkspaceLSPManager(
            registry: LanguageServerRegistry(userDefined: [unavailable]),
            makeClient: { _, _, _, language, rootURI in
                LSPClient(transport: transport, language: language, rootURI: rootURI)
            }
        )
        let buffer = EditorBuffer(
            worktreeRoot: root,
            relativePath: "main.swift",
            store: store,
            worktreeId: "wt",
            tabId: "t",
            lsp: lsp
        )
        await buffer.awaitLoadForTesting()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!transport.sent.contains { $0.contains(#""method":"textDocument/didOpen""#) })

        lsp.updateRegistry(LanguageServerRegistry(userDefined: [available]))
        buffer.reopenLSPDocument()
        for _ in 0..<20 where !transport.sent.contains(where: { $0.contains(#""method":"textDocument/didOpen""#) }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let didOpen = transport.sent.filter { $0.contains(#""method":"textDocument/didOpen""#) }
        #expect(didOpen.count == 1)
        #expect(didOpen.first?.contains(#""text":"print(1)\n""#) == true)
        buffer.close(persistDirtySnapshot: false)
        transport.finish()
    }

    @Test func revertReloadsFromDiskAndClearsDirty() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "original\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "junk")
        #expect(buffer.dirty == true)
        buffer.revert()
        await buffer.awaitLoadForTesting()
        #expect(buffer.storage.string == "original\n")
        #expect(buffer.dirty == false)
    }

    @Test func externalChangeWhileCleanReloadsSilently() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "v1\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        var fired = 0
        let token = buffer.onEdit { fired += 1 }
        defer { buffer.removeOnEdit(token) }
        buffer.startWatching()
        defer { buffer.stopWatching() }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "v2\n".write(to: url, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(buffer.storage.string == "v2\n")
        #expect(buffer.dirty == false)
        #expect(buffer.conflict == nil)
        #expect(fired >= 1)
    }

    @Test func externalRenameReloadsCleanBufferFromMovedFile() async throws {
        let root = tempWorktree()
        let oldURL = try writeFile(root, "a.txt", "v1\n")
        let newURL = root.appendingPathComponent("nested/b.txt")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        var pathChanges: [(String, String)] = []
        buffer.onPathChanged = { oldPath, newPath in pathChanges.append((oldPath, newPath)) }
        buffer.startWatching()
        defer { buffer.stopWatching() }

        try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        let handle = try FileHandle(forWritingTo: newURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("v2\n".utf8))
        try handle.close()
        for _ in 0..<20 where buffer.relativePath != "nested/b.txt" {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(buffer.relativePath == "nested/b.txt")
        #expect(buffer.storage.string == "v2\n")
        #expect(buffer.originalText == "v2\n")
        #expect(buffer.dirty == false)
        #expect(buffer.conflict == nil)
        #expect(pathChanges.count == 1)
        #expect(pathChanges.first?.0 == "a.txt")
        #expect(pathChanges.first?.1 == "nested/b.txt")
    }

    @Test func externalRenameOfDirtyBufferRaisesConflictWhenMovedFileChanged() async throws {
        let root = tempWorktree()
        let oldURL = try writeFile(root, "a.txt", "v1\n")
        let newURL = root.appendingPathComponent("nested/b.txt")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "mine")
        #expect(buffer.dirty == true)
        buffer.startWatching()
        defer { buffer.stopWatching() }

        try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        let handle = try FileHandle(forWritingTo: newURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("external\n".utf8))
        try handle.close()
        for _ in 0..<20 where buffer.relativePath != "nested/b.txt" {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(buffer.relativePath == "nested/b.txt")
        #expect(buffer.storage.string == "mine\n")
        #expect(buffer.originalText == "v1\n")
        #expect(buffer.dirty == true)
        #expect(buffer.conflict == .changedOnDisk)
    }

    @Test func externalRenameOfDirtyBufferReopensLSPAtMovedPath() async throws {
        let root = tempWorktree()
        let oldURL = try writeFile(root, "a.swift", "let value = 1\n")
        let newURL = root.appendingPathComponent("nested/b.swift")
        let store = EditorBufferStore(rootOverride: tempWorktree())
        let transport = FakeTransport()
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":1}}}"#)
            }
        }
        let lsp = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: "/usr/bin/true",
                args: [],
                env: [:],
                rootMarkers: [],
                enabled: true
            )
        ]), makeClient: { _, _, _, language, rootURI in
            LSPClient(transport: transport, language: language, rootURI: rootURI)
        })
        let buffer = EditorBuffer(
            worktreeRoot: root,
            relativePath: "a.swift",
            store: store,
            worktreeId: "wt",
            tabId: "t",
            lsp: lsp
        )
        await buffer.awaitLoadForTesting()
        for _ in 0..<20 where !transport.sent.contains(where: { $0.contains(#""method":"textDocument/didOpen""#) }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        buffer.storage.replaceCharacters(in: NSRange(location: 4, length: 5), with: "edited")
        try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldURL, to: newURL)

        buffer.finishMoveLookupForTest(movedRelativePath: "nested/b.swift", missingRelativePath: "a.swift")
        for _ in 0..<20 where transport.sent.filter({ $0.contains(#""method":"textDocument/didOpen""#) }).count < 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let didOpen = transport.sent.filter { $0.contains(#""method":"textDocument/didOpen""#) }
        #expect(didOpen.count == 2)
        #expect(didOpen.last?.contains("nested/b.swift") == true)
        #expect(didOpen.last?.contains(#""text":"let edited = 1\n""#) == true)
        #expect(transport.sent.filter { $0.contains(#""method":"textDocument/didClose""#) }.count == 1)
        buffer.close(persistDirtySnapshot: false)
        transport.finish()
    }

    @Test func externalRenameFollowsHiddenFiles() async throws {
        let root = tempWorktree()
        let oldURL = try writeFile(root, ".env", "TOKEN=a\n")
        let newURL = root.appendingPathComponent(".env.local")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: ".env")
        await buffer.awaitLoadForTesting()
        buffer.startWatching()
        defer { buffer.stopWatching() }

        try FileManager.default.moveItem(at: oldURL, to: newURL)
        for _ in 0..<20 where buffer.relativePath != ".env.local" {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(buffer.relativePath == ".env.local")
        #expect(buffer.storage.string == "TOKEN=a\n")
        #expect(buffer.conflict == nil)
    }

    @Test func externalRenameSkipsNodeModulesDescendants() async throws {
        let root = tempWorktree()
        let oldURL = try writeFile(root, "a.txt", "v1\n")
        let newURL = root.appendingPathComponent("node_modules/pkg/a.txt")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "mine")
        buffer.startWatching()
        defer { buffer.stopWatching() }

        try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        for _ in 0..<20 where buffer.conflict != .deletedOnDisk {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(buffer.relativePath == "a.txt")
        #expect(buffer.storage.string == "mine\n")
        #expect(buffer.conflict == .deletedOnDisk)
    }

    @Test func externalChangeWhileDirtyRaisesConflict() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "v1\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.startWatching()
        defer { buffer.stopWatching() }
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "edited ")
        #expect(buffer.dirty == true)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "external\n".write(to: url, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(buffer.conflict == .changedOnDisk)
        #expect(buffer.storage.string == "edited v1\n")
        #expect(buffer.dirty == true)
    }

    @Test func resolveConflictByKeepingMineClearsConflictAdvancesMtime() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "v1\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.startWatching()
        defer { buffer.stopWatching() }
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "edited ")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "external\n".write(to: url, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 500_000_000)
        let onDiskMtime = (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        buffer.resolveConflictKeepingMine()
        #expect(buffer.conflict == nil)
        #expect(buffer.originalMtime == onDiskMtime)
        #expect(buffer.dirty == true)
    }

    @Test func resolveConflictByReloadingFromDiskReplacesContent() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "v1\n")
        let store = EditorBufferStore(rootOverride: tempWorktree())
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt", store: store, worktreeId: "wt", tabId: "t")
        await buffer.awaitLoadForTesting()
        buffer.startWatching()
        defer { buffer.stopWatching() }
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "edited ")
        buffer.snapshotNow()
        #expect(try store.read(worktreeId: "wt", tabId: "t") != nil)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "external\n".write(to: url, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 500_000_000)
        buffer.resolveConflictReloadingFromDisk()
        await buffer.awaitLoadForTesting()
        #expect(buffer.conflict == nil)
        #expect(buffer.dirty == false)
        #expect(buffer.storage.string == "external\n")
        #expect(try store.read(worktreeId: "wt", tabId: "t") == nil)
    }

    @Test func deletionOnDiskRaisesDeletedConflict() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "v1\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.startWatching()
        defer { buffer.stopWatching() }
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "edited ")
        try FileManager.default.removeItem(at: url)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(buffer.conflict == .deletedOnDisk)
        #expect(buffer.dirty == true)
    }

    @Test func recreatedOriginalPathWhileDirtyRaisesChangedConflict() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "v1\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "mine")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "external\n".write(to: url, atomically: true, encoding: .utf8)

        buffer.handleRecreatedOriginalPathForTest()

        #expect(buffer.conflict == .changedOnDisk)
        #expect(buffer.storage.string == "mine\n")
        #expect(buffer.dirty == true)
    }

    @Test func recreatedOriginalPathWhileCleanReloadsAndRearmsWatcher() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "v1\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "v2\n".write(to: url, atomically: true, encoding: .utf8)

        buffer.handleRecreatedOriginalPathForTest()
        await buffer.awaitLoadForTesting()

        #expect(buffer.storage.string == "v2\n")
        #expect(buffer.originalText == "v2\n")
        #expect(buffer.dirty == false)
        #expect(buffer.conflict == nil)
        buffer.stopWatching()
    }

    @Test func movedFileLookupPrefersFoundMoveOverRecreatedOriginalPath() async throws {
        let root = tempWorktree()
        let originalURL = try writeFile(root, "a.txt", "v1\n")
        let movedURL = root.appendingPathComponent("b.txt")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        try FileManager.default.moveItem(at: originalURL, to: movedURL)
        _ = try writeFile(root, "a.txt", "replacement\n")

        buffer.finishMoveLookupForTest(movedRelativePath: "b.txt", missingRelativePath: "a.txt")

        #expect(buffer.relativePath == "b.txt")
        #expect(buffer.storage.string == "v1\n")
        #expect(buffer.originalText == "v1\n")
        #expect(buffer.dirty == false)
        #expect(buffer.conflict == nil)
        buffer.stopWatching()
    }

    @Test func snapshotRestoreRoundTrip() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "v1\n")
        let store = EditorBufferStore(rootOverride: tempWorktree())
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt", store: store, worktreeId: "wt", tabId: "t")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "edited ")
        buffer.snapshotNow()
        let restored = EditorBuffer(worktreeRoot: root, relativePath: "a.txt", store: store, worktreeId: "wt", tabId: "t")
        await restored.awaitLoadForTesting()
        #expect(restored.storage.string == "edited v1\n")
        #expect(restored.dirty == true)
        #expect(restored.originalText == "v1\n")
    }

    @Test func closeSnapshotsThenDiscardsOnSave() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "v1\n")
        let storeRoot = tempWorktree()
        let store = EditorBufferStore(rootOverride: storeRoot)
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt", store: store, worktreeId: "wt", tabId: "t")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        buffer.close()
        #expect(try store.read(worktreeId: "wt", tabId: "t") != nil)
        let again = EditorBuffer(worktreeRoot: root, relativePath: "a.txt", store: store, worktreeId: "wt", tabId: "t")
        await again.awaitLoadForTesting()
        try again.save()
        #expect(try store.read(worktreeId: "wt", tabId: "t") == nil)
    }

    @Test func snapshotNowDiscardsStaleSnapshotWhenBufferIsClean() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "v1\n")
        let store = EditorBufferStore(rootOverride: tempWorktree())
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt", store: store, worktreeId: "wt", tabId: "t")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "edited ")
        buffer.snapshotNow()
        #expect(try store.read(worktreeId: "wt", tabId: "t") != nil)

        buffer.storage.setAttributedString(NSAttributedString(string: "v1\n"))
        buffer.snapshotNow()

        #expect(buffer.dirty == false)
        #expect(try store.read(worktreeId: "wt", tabId: "t") == nil)
    }

    @Test func restoreOnDifferentMtimeRaisesConflict() async throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "v1\n")
        let storeRoot = tempWorktree()
        let store = EditorBufferStore(rootOverride: storeRoot)
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt", store: store, worktreeId: "wt", tabId: "t")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "edited ")
        buffer.snapshotNow()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "v2\n".write(to: url, atomically: true, encoding: .utf8)
        let restored = EditorBuffer(worktreeRoot: root, relativePath: "a.txt", store: store, worktreeId: "wt", tabId: "t")
        await restored.awaitLoadForTesting()
        restored.startWatching()
        defer { restored.stopWatching() }
        restored.checkForConflictOnRestore()
        #expect(restored.conflict == .changedOnDisk)
    }

    @Test func coordinatorDetachRemovesMountedLayoutManager() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "v1\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        let coordinator = CodeEditorCoordinator(appState: AppState())
        let theme = try ThemeStore().current

        coordinator.attach(
            textView: textView,
            buffer: buffer,
            layoutManager: layoutManager,
            worktreeId: "wt",
            worktreeRoot: root,
            tabId: "t",
            revealLine: nil,
            revealCharacter: nil,
            theme: theme
        )
        #expect(buffer.storage.layoutManagers.contains { $0 === layoutManager })

        coordinator.detach()

        #expect(!buffer.storage.layoutManagers.contains { $0 === layoutManager })
    }

    @Test func coordinatorRestoresSelectionAndScrollPositionAfterRemount() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", String(repeating: "0123456789\n", count: 200))
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        let theme = try ThemeStore().current

        func mount() -> (CodeEditorCoordinator, CodeTextView, NSScrollView) {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.contentView = CodeEditorLeadingClipView(frame: .zero)
            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(size: NSSize(width: 1_200, height: 2_400))
            layoutManager.addTextContainer(textContainer)
            let textView = CodeTextView(
                frame: NSRect(x: 0, y: 0, width: 1_200, height: 2_400),
                textContainer: textContainer
            )
            scrollView.documentView = textView
            let coordinator = CodeEditorCoordinator(appState: AppState())
            coordinator.attach(
                textView: textView,
                buffer: buffer,
                layoutManager: layoutManager,
                worktreeId: "wt",
                worktreeRoot: root,
                tabId: "t",
                revealLine: nil,
                revealCharacter: nil,
                theme: theme
            )
            return (coordinator, textView, scrollView)
        }

        let first = mount()
        let expectedSelections = [
            NSValue(range: NSRange(location: 150, length: 7)),
            NSValue(range: NSRange(location: 250, length: 0)),
        ]
        let expectedOrigin = NSPoint(x: 45, y: 160)
        first.1.setSelectedRanges(expectedSelections, affinity: .downstream, stillSelecting: false)
        first.2.contentView.scroll(to: expectedOrigin)
        #expect(first.2.contentView.bounds.origin == expectedOrigin)
        first.0.detach()

        let restored = mount()
        let deadline = Date(timeIntervalSinceNow: 1)
        while (restored.1.selectedRanges != expectedSelections
            || restored.2.contentView.bounds.origin != expectedOrigin), Date() < deadline {
            await Task.yield()
        }

        #expect(restored.1.selectedRanges == expectedSelections)
        #expect(restored.2.contentView.bounds.origin == expectedOrigin)
    }

    @Test func coordinatorRestoresSelectionAndScrollPositionAfterRebind() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", String(repeating: "0123456789\n", count: 200))
        _ = try writeFile(root, "b.txt", String(repeating: "abcdefghij\n", count: 200))
        let appState = AppState()
        let buffer = appState.tabs.buffer(worktreeId: "wt", tabId: "a", worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        _ = appState.tabs.buffer(worktreeId: "wt", tabId: "b", worktreeRoot: root, relativePath: "b.txt")
        let theme = try ThemeStore().current
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        scrollView.contentView = CodeEditorLeadingClipView(frame: .zero)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 1_200, height: 2_400))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 2_400), textContainer: textContainer)
        scrollView.documentView = textView
        let coordinator = CodeEditorCoordinator(appState: appState)
        coordinator.attach(textView: textView, buffer: buffer, layoutManager: layoutManager, worktreeId: "wt", worktreeRoot: root, tabId: "a", revealLine: nil, revealCharacter: nil, theme: theme)

        let expectedSelections = [
            NSValue(range: NSRange(location: 150, length: 7)),
            NSValue(range: NSRange(location: 250, length: 0)),
        ]
        let expectedOrigin = NSPoint(x: 45, y: 160)
        textView.setSelectedRanges(expectedSelections, affinity: .downstream, stillSelecting: false)
        scrollView.contentView.scroll(to: expectedOrigin)
        coordinator.updateIfNeeded(worktreeId: "wt", worktreeRoot: root, relativePath: "b.txt", tabId: "b", revealLine: nil, revealCharacter: nil, theme: theme)
        coordinator.updateIfNeeded(worktreeId: "wt", worktreeRoot: root, relativePath: "a.txt", tabId: "a", revealLine: nil, revealCharacter: nil, theme: theme)

        let deadline = Date(timeIntervalSinceNow: 1)
        while (textView.selectedRanges != expectedSelections
            || scrollView.contentView.bounds.origin != expectedOrigin), Date() < deadline {
            await Task.yield()
        }

        #expect(textView.selectedRanges == expectedSelections)
        #expect(scrollView.contentView.bounds.origin == expectedOrigin)
    }

    @Test func coordinatorKeepsSamePathTabViewStatesIndependent() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", String(repeating: "0123456789\n", count: 200))
        let appState = AppState()
        let buffer = appState.tabs.buffer(worktreeId: "wt", tabId: "a", worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        #expect(appState.tabs.buffer(worktreeId: "wt", tabId: "b", worktreeRoot: root, relativePath: "a.txt") === buffer)
        let theme = try ThemeStore().current
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        scrollView.contentView = CodeEditorLeadingClipView(frame: .zero)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 1_200, height: 2_400))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 2_400), textContainer: textContainer)
        scrollView.documentView = textView
        let coordinator = CodeEditorCoordinator(appState: appState)
        coordinator.attach(textView: textView, buffer: buffer, layoutManager: layoutManager, worktreeId: "wt", worktreeRoot: root, tabId: "a", revealLine: nil, revealCharacter: nil, theme: theme)

        let tabASelections = [NSValue(range: NSRange(location: 150, length: 7))]
        let tabBSelections = [NSValue(range: NSRange(location: 260, length: 3))]
        textView.setSelectedRanges(tabASelections, affinity: .downstream, stillSelecting: false)
        scrollView.contentView.scroll(to: NSPoint(x: 45, y: 160))
        coordinator.updateIfNeeded(worktreeId: "wt", worktreeRoot: root, relativePath: "a.txt", tabId: "b", revealLine: nil, revealCharacter: nil, theme: theme)
        #expect(scrollView.contentView.bounds.origin == .zero)
        textView.setSelectedRanges(tabBSelections, affinity: .downstream, stillSelecting: false)
        scrollView.contentView.scroll(to: NSPoint(x: 10, y: 20))
        coordinator.updateIfNeeded(worktreeId: "wt", worktreeRoot: root, relativePath: "a.txt", tabId: "a", revealLine: nil, revealCharacter: nil, theme: theme)
        coordinator.updateIfNeeded(worktreeId: "wt", worktreeRoot: root, relativePath: "a.txt", tabId: "b", revealLine: nil, revealCharacter: nil, theme: theme)
        coordinator.updateIfNeeded(worktreeId: "wt", worktreeRoot: root, relativePath: "a.txt", tabId: "a", revealLine: nil, revealCharacter: nil, theme: theme)

        let deadline = Date(timeIntervalSinceNow: 1)
        while (textView.selectedRanges != tabASelections
            || scrollView.contentView.bounds.origin != NSPoint(x: 45, y: 160)), Date() < deadline {
            await Task.yield()
        }

        #expect(textView.selectedRanges == tabASelections)
        #expect(scrollView.contentView.bounds.origin == NSPoint(x: 45, y: 160))
    }

    @Test func coordinatorCallsDirectAttachAndDetachCallbacks() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "v1\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        let coordinator = CodeEditorCoordinator(appState: AppState())
        let theme = try ThemeStore().current
        var attachedTextView: CodeTextView?
        var attachedTabId: TabID?
        var detachedTabId: TabID?

        coordinator.onTextViewAttached = { textView, tabId in
            attachedTextView = textView
            attachedTabId = tabId
        }
        coordinator.onTextViewDetached = { _, tabId in
            detachedTabId = tabId
        }

        coordinator.attach(
            textView: textView,
            buffer: buffer,
            layoutManager: layoutManager,
            worktreeId: "wt",
            worktreeRoot: root,
            tabId: "t",
            revealLine: nil,
            revealCharacter: nil,
            theme: theme
        )
        #expect(attachedTextView === textView)
        #expect(attachedTabId == "t")

        coordinator.detach()

        #expect(detachedTabId == "t")
    }

    @Test func coordinatorAppliesMonospacedFontToLoadedContent() async throws {
        // Regression: after rebinding, applyBaseStyle was reading
        // `textView.font` whose getter falls back to the system default font
        // (proportional) when the freshly bound storage has no `.font`
        // attribute on char 0. The styled storage ended up with a
        // proportional font for existing content while typing remained
        // monospaced.
        let root = tempWorktree()
        _ = try writeFile(root, "a.swift", "let answer = 42\n")
        let appState = AppState()
        // Use a guaranteed-available system monospace font so the test
        // doesn't depend on whether the bundled Nerd Font is registered
        // in the test process.
        appState.config.code.fontFamily = "Menlo"
        let buffer = appState.tabs.buffer(
            worktreeId: "wt",
            tabId: "tab",
            worktreeRoot: root,
            relativePath: "a.swift"
        )
        await buffer.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current

        coordinator.attach(
            textView: textView,
            buffer: buffer,
            layoutManager: layoutManager,
            worktreeId: "wt",
            worktreeRoot: root,
            tabId: "tab",
            revealLine: nil,
            revealCharacter: nil,
            theme: theme
        )

        let appliedFont = buffer.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(appliedFont != nil)
        #expect(appliedFont?.isFixedPitch == true)
    }

    @Test func coordinatorPathChangeRebindsLayoutManagerToNewBufferStorage() async throws {
        // Regression: when the active editor tab switched, the coordinator
        // updated its bookkeeping but never moved the layout manager off the
        // first buffer's NSTextStorage, so the text view kept rendering the
        // first file's contents for every subsequent tab.
        let root = tempWorktree()
        _ = try writeFile(root, "a.md", "alpha\n")
        _ = try writeFile(root, "b.swift", "let beta = 1\n")
        let appState = AppState()
        appState.config.code.fontFamily = "Menlo"
        let bufferA = appState.tabs.buffer(
            worktreeId: "wt",
            tabId: "tab-a",
            worktreeRoot: root,
            relativePath: "a.md"
        )
        await bufferA.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current

        coordinator.attach(
            textView: textView,
            buffer: bufferA,
            layoutManager: layoutManager,
            worktreeId: "wt",
            worktreeRoot: root,
            tabId: "tab-a",
            revealLine: nil,
            revealCharacter: nil,
            theme: theme
        )
        #expect(bufferA.storage.layoutManagers.contains { $0 === layoutManager })

        coordinator.updateIfNeeded(
            worktreeId: "wt",
            worktreeRoot: root,
            relativePath: "b.swift",
            tabId: "tab-b",
            revealLine: nil,
            revealCharacter: nil,
            theme: theme
        )

        let bufferB = appState.tabs.buffer(
            worktreeId: "wt",
            tabId: "tab-b",
            worktreeRoot: root,
            relativePath: "b.swift"
        )
        await bufferB.awaitLoadForTesting()
        #expect(!bufferA.storage.layoutManagers.contains { $0 === layoutManager })
        #expect(bufferB.storage.layoutManagers.contains { $0 === layoutManager })
        // The newly bound storage must come back styled monospaced. The
        // original bug here was that applyBaseStyle resolved the font from
        // textView.font, which after rebinding read char 0 of the new
        // (unstyled) storage and fell back to the proportional system font.
        let fontB = bufferB.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(fontB?.isFixedPitch == true)
    }

    @Test func coordinatorReappliesSameRevealTargetWhenRevisionChanges() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.swift", "line one\nline two\nline three\n")
        let appState = AppState()
        appState.config.code.fontFamily = "Menlo"
        let buffer = appState.tabs.buffer(
            worktreeId: "wt",
            tabId: "tab-a",
            worktreeRoot: root,
            relativePath: "a.swift"
        )
        await buffer.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current

        coordinator.attach(
            textView: textView,
            buffer: buffer,
            layoutManager: layoutManager,
            worktreeId: "wt",
            worktreeRoot: root,
            tabId: "tab-a",
            revealLine: 1,
            revealCharacter: 0,
            revealRevision: 0,
            theme: theme
        )

        let revealedSelection = textView.selectedRange()
        #expect(revealedSelection.location > 0)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let findHighlightColor = NSColor.systemBlue
        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: findHighlightColor,
            forCharacterRange: NSRange(location: revealedSelection.location, length: 4)
        )
        coordinator.updateIfNeeded(
            worktreeId: "wt",
            worktreeRoot: root,
            relativePath: "a.swift",
            tabId: "tab-a",
            revealLine: 1,
            revealCharacter: 0,
            revealRevision: 0,
            theme: theme
        )
        #expect(textView.selectedRange().location == 0)

        coordinator.updateIfNeeded(
            worktreeId: "wt",
            worktreeRoot: root,
            relativePath: "a.swift",
            tabId: "tab-a",
            revealLine: 1,
            revealCharacter: 0,
            revealRevision: 1,
            theme: theme
        )
        #expect(textView.selectedRange() == revealedSelection)
        let preservedBackground = layoutManager.temporaryAttribute(
            .backgroundColor,
            atCharacterIndex: revealedSelection.location,
            effectiveRange: nil
        ) as? NSColor
        #expect(preservedBackground == findHighlightColor)
    }

    @Test func coordinatorRevealHighlightsThroughTheEndLine() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.swift", "line one\nline two\nline three\nline four\n")
        let appState = AppState()
        let buffer = appState.tabs.buffer(
            worktreeId: "wt",
            tabId: "tab-a",
            worktreeRoot: root,
            relativePath: "a.swift"
        )
        await buffer.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            textContainer: textContainer
        )
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current

        coordinator.attach(
            textView: textView,
            buffer: buffer,
            layoutManager: layoutManager,
            worktreeId: "wt",
            worktreeRoot: root,
            tabId: "tab-a",
            revealLine: 0,
            revealEndLine: 2,
            revealCharacter: 0,
            theme: theme
        )

        let text = buffer.storage.string as NSString
        let firstLineStart = text.range(of: "line one").location
        let secondLineStart = text.range(of: "line two").location
        let thirdLineStart = text.range(of: "line three").location
        let fourthLineStart = text.range(of: "line four").location
        #expect(layoutManager.temporaryAttribute(
            .underlineStyle,
            atCharacterIndex: firstLineStart,
            effectiveRange: nil
        ) != nil)
        #expect(layoutManager.temporaryAttribute(
            .underlineStyle,
            atCharacterIndex: secondLineStart,
            effectiveRange: nil
        ) != nil)
        #expect(layoutManager.temporaryAttribute(
            .underlineStyle,
            atCharacterIndex: thirdLineStart,
            effectiveRange: nil
        ) != nil)
        #expect(layoutManager.temporaryAttribute(
            .underlineStyle,
            atCharacterIndex: fourthLineStart,
            effectiveRange: nil
        ) == nil)

        coordinator.updateIfNeeded(
            worktreeId: "wt",
            worktreeRoot: root,
            relativePath: "a.swift",
            tabId: "tab-a",
            revealLine: 0,
            revealEndLine: 99,
            revealCharacter: 0,
            revealRevision: 1,
            theme: theme
        )
        #expect(layoutManager.temporaryAttribute(
            .underlineStyle,
            atCharacterIndex: fourthLineStart,
            effectiveRange: nil
        ) != nil)
    }

    @Test func coordinatorAppliesPendingRevealAfterLoadAndConsumesOutOfRangeTarget() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.swift", "line one\nline two\n")
        let gate = AsyncLoadGate()
        EditorBuffer.loadGateForTesting = { await gate.wait() }
        defer { EditorBuffer.loadGateForTesting = nil }
        let appState = AppState()
        let tab = appState.tabs.openEditor(
            worktreeId: "wt",
            relativePath: "a.swift",
            revealLine: 99,
            revealCharacter: 0,
            revealEndLine: 120
        )
        let buffer = appState.tabs.buffer(
            worktreeId: "wt",
            tabId: tab.id,
            worktreeRoot: root,
            relativePath: "a.swift"
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            textContainer: textContainer
        )
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current

        coordinator.attach(
            textView: textView,
            buffer: buffer,
            layoutManager: layoutManager,
            worktreeId: "wt",
            worktreeRoot: root,
            tabId: tab.id,
            revealLine: 99,
            revealEndLine: 120,
            revealCharacter: 0,
            theme: theme
        )
        await gate.open()
        await buffer.awaitLoadForTesting()

        let deadline = Date().addingTimeInterval(2)
        let tabId = tab.id
        while Date() < deadline {
            let consumed = appState.tabs.tabs(forWorktree: "wt").contains { candidate in
                guard case .editor(let state) = candidate, state.id == tabId else { return false }
                return state.revealLine == nil
                    && state.revealEndLine == nil
                    && state.revealCharacter == nil
            }
            if consumed { break }
            await Task.yield()
        }
        #expect(textView.selectedRange().location == (buffer.storage.string as NSString).length)
        if let updated = appState.tabs.tabs(forWorktree: "wt").first(where: { $0.id == tabId }),
           case .editor(let state) = updated {
            #expect(state.revealLine == nil)
            #expect(state.revealEndLine == nil)
            #expect(state.revealCharacter == nil)
        } else {
            Issue.record("expected editor tab")
        }
    }

    @Test func coordinatorRevealKeepsEditorHorizontallyAtLeadingEdge() async throws {
        let root = tempWorktree()
        let prefix = String(repeating: "0123456789 ", count: 40)
        _ = try writeFile(root, "a.swift", "short\n\(prefix)target\n")
        let appState = AppState()
        appState.config.code.fontFamily = "Menlo"
        let buffer = appState.tabs.buffer(
            worktreeId: "wt",
            tabId: "tab-a",
            worktreeRoot: root,
            relativePath: "a.swift"
        )
        await buffer.awaitLoadForTesting()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(
            frame: NSRect(x: 0, y: 0, width: 220, height: 120),
            textContainer: textContainer
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        scrollView.documentView = textView
        scrollView.layoutSubtreeIfNeeded()
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current

        coordinator.attach(
            textView: textView,
            buffer: buffer,
            layoutManager: layoutManager,
            worktreeId: "wt",
            worktreeRoot: root,
            tabId: "tab-a",
            revealLine: 1,
            revealCharacter: prefix.utf16.count,
            revealRevision: 0,
            theme: theme
        )

        #expect(textView.selectedRange().location > prefix.utf16.count)
        #expect(scrollView.contentView.bounds.origin.x == 0)
    }

    /// Regression for the gutter clipping the leading characters of every line:
    /// AppKit shifts the clip's bounds origin to `-rulerThickness` so document
    /// content clears a left-side vertical ruler. `CodeEditorLeadingClipView`
    /// must honor that negative leading origin instead of pinning it to 0,
    /// otherwise the first ~6 characters hide under the line-number gutter with
    /// no way to scroll them back. Uses a plain `NSClipView` as the oracle for
    /// the correct ruler-aware leading position.
    @Test func codeEditorLeadingClipViewKeepsRulerGutterClear() throws {
        let theme = try ThemeStore().current

        func makeScroll(custom: Bool) -> NSScrollView {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = false
            if custom {
                scrollView.contentView = CodeEditorLeadingClipView(frame: .zero)
            }
            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(size: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ))
            textContainer.widthTracksTextView = false
            textContainer.heightTracksTextView = false
            layoutManager.addTextContainer(textContainer)
            let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: textContainer)
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.isVerticallyResizable = true
            textView.autoresizingMask = []
            // A line long enough that the document is wider than the viewport.
            textView.string = String(repeating: "x", count: 4000)
            scrollView.documentView = textView
            let ruler = CodeEditorLineNumberRulerView(scrollView: scrollView, textView: textView, theme: theme)
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
            scrollView.tile()
            scrollView.layoutSubtreeIfNeeded()
            return scrollView
        }

        // A plain NSClipView rests at a negative leading origin (it reserves the
        // gutter by shifting bounds left by the ruler thickness). This confirms
        // the correct leading edge is negative, not 0.
        let oracle = makeScroll(custom: false)
        #expect(oracle.contentView.bounds.origin.x < 0)

        // The custom clip must reach that same negative leading edge when the
        // user scrolls fully left — not clamp it to 0 and hide the gutter-width
        // of leading characters.
        let subject = makeScroll(custom: true)
        let expectedLeadingX = -(subject.verticalRulerView?.requiredThickness ?? 0)
        #expect(expectedLeadingX < 0)
        subject.contentView.scroll(to: NSPoint(x: -10_000, y: 0))
        subject.reflectScrolledClipView(subject.contentView)
        #expect(subject.contentView.bounds.origin.x == expectedLeadingX)

        // Force a document genuinely wider than the viewport so a horizontal
        // scroll range exists (headless text layout won't grow the text view on
        // its own). The clip width is unchanged by a document resize.
        let clipW = subject.contentView.bounds.width
        subject.documentView?.setFrameSize(NSSize(width: clipW + 4000, height: 300))

        // The actual production failure: AppKit's layout/frame-change passes
        // propose x == 0 (treating 0 as the leading edge, unaware of the gutter
        // offset). That exact reset must settle at the true leading edge,
        // otherwise the leading characters race under the gutter.
        let constrainedZero = subject.contentView.constrainBoundsRect(
            NSRect(x: 0, y: 0, width: clipW, height: subject.contentView.bounds.height)
        )
        #expect(constrainedZero.origin.x == expectedLeadingX)

        // Regression: an incremental scroll right from the leading edge
        // (leadingX + delta) must be preserved, not collapsed back to the
        // leading edge — otherwise the user can't start scrolling until a
        // single event jumps the whole gutter width.
        let incremental = subject.contentView.constrainBoundsRect(
            NSRect(x: expectedLeadingX + 5, y: 0, width: clipW, height: subject.contentView.bounds.height)
        )
        #expect(incremental.origin.x == expectedLeadingX + 5)

        // Exact zero is a valid user-driven scroll position. Starting at the
        // negative gutter edge and landing exactly on zero must not be mistaken
        // for AppKit's layout reset above.
        subject.contentView.scroll(to: NSPoint(x: expectedLeadingX, y: 0))
        subject.contentView.scroll(to: NSPoint(x: 0, y: 0))
        subject.reflectScrolledClipView(subject.contentView)
        #expect(subject.contentView.bounds.origin.x == 0)

        subject.contentView.setBoundsOrigin(NSPoint(x: expectedLeadingX, y: 0))
        subject.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        #expect(subject.contentView.bounds.origin.x == 0)

        // Positive origins scroll long lines normally.
        let positive = subject.contentView.constrainBoundsRect(
            NSRect(x: 30, y: 0, width: clipW, height: subject.contentView.bounds.height)
        )
        #expect(positive.origin.x == 30)
    }

    @Test func coordinatorClampsStaleRevealHighlightRangeAfterEdit() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.swift", "line one\nline two\nline three\n")
        let appState = AppState()
        appState.config.code.fontFamily = "Menlo"
        let buffer = appState.tabs.buffer(
            worktreeId: "wt",
            tabId: "tab-a",
            worktreeRoot: root,
            relativePath: "a.swift"
        )
        await buffer.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current

        coordinator.attach(
            textView: textView,
            buffer: buffer,
            layoutManager: layoutManager,
            worktreeId: "wt",
            worktreeRoot: root,
            tabId: "tab-a",
            revealLine: 1,
            revealCharacter: 0,
            revealRevision: 0,
            theme: theme
        )
        #expect(textView.selectedRange().location > 0)

        buffer.storage.replaceCharacters(
            in: NSRange(location: 0, length: buffer.storage.length),
            with: "x\n"
        )

        coordinator.updateIfNeeded(
            worktreeId: "wt",
            worktreeRoot: root,
            relativePath: "a.swift",
            tabId: "tab-a",
            revealLine: 0,
            revealCharacter: 0,
            revealRevision: 1,
            theme: theme
        )

        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func coordinatorRebindsActiveExternalEditorWhenLanguageAppears() async throws {
        let root = tempWorktree()
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-language-\(UUID().uuidString).foo")
        try "value\n".write(to: externalURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: externalURL) }

        let appState = AppState()
        let buffer = appState.tabs.externalBuffer(
            worktreeId: "wt",
            tabId: "external-tab",
            absoluteURL: externalURL,
            worktreeRoot: root,
            originatingFileURL: nil,
            language: nil
        )
        await buffer.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current

        coordinator.attach(
            textView: textView,
            buffer: buffer,
            layoutManager: layoutManager,
            worktreeId: "wt",
            worktreeRoot: root,
            tabId: "external-tab",
            revealLine: nil,
            revealCharacter: nil,
            theme: theme,
            externalAbsolutePath: externalURL.path,
            originatingRelativePath: nil
        )
        #expect(textView.indentationMode == .plain)

        appState.lsp.updateRegistry(LanguageServerRegistry(userDefined: [
            LanguageServerConfig(
                language: "foo",
                extensions: ["foo"],
                command: "foo-lsp",
                args: [],
                env: [:],
                rootMarkers: [".git"],
                enabled: true
            )
        ]))

        coordinator.updateIfNeeded(
            worktreeId: "wt",
            worktreeRoot: root,
            relativePath: externalURL.lastPathComponent,
            tabId: "external-tab",
            revealLine: nil,
            revealCharacter: nil,
            theme: theme,
            externalAbsolutePath: externalURL.path,
            originatingRelativePath: nil
        )

        #expect(textView.indentationMode == .bracketAware)
    }

    @Test func coordinatorPathChangeDropsStaleDiagnostics() async throws {
        // Regression: runHighlight captures diagnosticsFeature.current at the
        // start of its async task; if we don't reset before the rebind, the
        // task can re-apply the previous file's diagnostics onto the newly
        // bound storage.
        let root = tempWorktree()
        _ = try writeFile(root, "a.swift", "let a = 1\n")
        _ = try writeFile(root, "b.swift", "let b = 2\n")
        let appState = AppState()
        let bufferA = appState.tabs.buffer(
            worktreeId: "wt", tabId: "tab-a",
            worktreeRoot: root, relativePath: "a.swift"
        )
        await bufferA.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current
        coordinator.attach(
            textView: textView, buffer: bufferA, layoutManager: layoutManager,
            worktreeId: "wt", worktreeRoot: root, tabId: "tab-a",
            revealLine: nil, revealCharacter: nil, theme: theme
        )

        // LSPDiagnostic only has a Codable init, so build via JSON.
        let json = #"{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"severity":1,"message":"boom"}"#
        let fakeDiag = try JSONDecoder().decode(LSPDiagnostic.self, from: Data(json.utf8))
        coordinator.diagnosticsFeature.apply([fakeDiag], to: bufferA.storage, theme: theme)
        #expect(coordinator.diagnosticsFeature.current.count == 1)

        coordinator.updateIfNeeded(
            worktreeId: "wt", worktreeRoot: root,
            relativePath: "b.swift", tabId: "tab-b",
            revealLine: nil, revealCharacter: nil, theme: theme
        )

        #expect(coordinator.diagnosticsFeature.current.isEmpty)
    }

    @Test func coordinatorRebindRestoresCachedDiagnosticsForKnownURI() async throws {
        // Regression: the LSP server doesn't replay past publishDiagnostics
        // batches to new subscribers. Without an in-coordinator cache, a
        // tab switch to a previously-open file would lose its squiggles
        // until the server happened to publish again. We cache every batch
        // we see and restore from it on rebind.
        let root = tempWorktree()
        _ = try writeFile(root, "a.swift", "let a = 1\n")
        _ = try writeFile(root, "b.swift", "let b = 2\n")
        let appState = AppState()
        let bufferA = appState.tabs.buffer(
            worktreeId: "wt", tabId: "tab-a",
            worktreeRoot: root, relativePath: "a.swift"
        )
        await bufferA.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current
        coordinator.attach(
            textView: textView, buffer: bufferA, layoutManager: layoutManager,
            worktreeId: "wt", worktreeRoot: root, tabId: "tab-a",
            revealLine: nil, revealCharacter: nil, theme: theme
        )

        // Seed the per-URI cache as if the LSP had published diagnostics
        // for A while we were attached.
        let uriA = root.appendingPathComponent("a.swift").lspURI
        let json = #"{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"severity":1,"message":"boom"}"#
        let fakeDiag = try JSONDecoder().decode(LSPDiagnostic.self, from: Data(json.utf8))
        coordinator.lastDiagnosticsByURI[uriA] = [fakeDiag]
        coordinator.diagnosticsFeature.apply([fakeDiag], to: bufferA.storage, theme: theme)
        #expect(bufferA.storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)

        // Switch to B (no cached diagnostics for B), then back to A.
        coordinator.updateIfNeeded(
            worktreeId: "wt", worktreeRoot: root,
            relativePath: "b.swift", tabId: "tab-b",
            revealLine: nil, revealCharacter: nil, theme: theme
        )
        coordinator.updateIfNeeded(
            worktreeId: "wt", worktreeRoot: root,
            relativePath: "a.swift", tabId: "tab-a",
            revealLine: nil, revealCharacter: nil, theme: theme
        )

        // Cached diagnostics for A should be re-applied to its storage —
        // the underline attribute the diagnosticsFeature paints should be
        // present again, even though no LSP server is running in this
        // headless test.
        let underline = bufferA.storage.attribute(.underlineStyle, at: 0, effectiveRange: nil)
        #expect(underline != nil)
    }

    @Test func coordinatorIgnoresDiagnosticsBatchForNonActiveURI() async throws {
        // Regression: cancelling the old diagnostics subscription on tab
        // switch doesn't synchronously drain in-flight batches. A batch
        // delivered after the rebind would otherwise pass the captured-URI
        // guard and paint onto the *new* buffer's storage. The fix checks
        // the batch URI against the currently bound buffer's URI.
        let root = tempWorktree()
        _ = try writeFile(root, "a.swift", "let a = 1\n")
        _ = try writeFile(root, "b.swift", "let b = 2\n")
        let appState = AppState()
        let bufferA = appState.tabs.buffer(
            worktreeId: "wt", tabId: "tab-a",
            worktreeRoot: root, relativePath: "a.swift"
        )
        await bufferA.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current
        coordinator.attach(
            textView: textView, buffer: bufferA, layoutManager: layoutManager,
            worktreeId: "wt", worktreeRoot: root, tabId: "tab-a",
            revealLine: nil, revealCharacter: nil, theme: theme
        )

        // Build a batch addressed to file B but feed it to the coordinator
        // while A is still the active buffer — simulating an in-flight
        // batch that beat the rebind.
        let uriB = root.appendingPathComponent("b.swift").lspURI
        let json = #"{"uri":"\#(uriB)","diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"severity":1,"message":"boom"}]}"#
        let batch = try JSONDecoder().decode(LSPPublishDiagnosticsParams.self, from: Data(json.utf8))

        coordinator.processDiagnosticsBatch(batch, theme: theme)

        // Cache must be updated regardless of the active buffer …
        #expect(coordinator.lastDiagnosticsByURI[uriB]?.count == 1)
        // … but the batch must not paint onto A's storage.
        #expect(bufferA.storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
    }

    @Test func externalBufferLoadsContentsAndIsReadOnly() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ext-\(UUID().uuidString).h")
        try "external content\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let buffer = EditorBuffer(externalAbsoluteURL: url)
        await buffer.awaitLoadForTesting()
        #expect(buffer.storage.string == "external content\n")
        #expect(buffer.isExternal == true)
        #expect(buffer.dirty == false)
    }

    @Test func externalBufferSaveIsNoOp() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ext-\(UUID().uuidString).h")
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = EditorBuffer(externalAbsoluteURL: url)
        await buffer.awaitLoadForTesting()
        // Mutate storage as if user typed (test-only — production sets isEditable=false on the view)
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "INJECTED ")
        // save() returns Void and is a no-op for external buffers (readOnly=true guard fires).
        try buffer.save()
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "x\n")
    }

    @Test func codeEditorLeadingClipViewPinsNegativeHorizontalOriginToZero() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        scroll.contentView = CodeEditorLeadingClipView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = false

        let text = CodeTextView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300), textContainer: nil)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = []
        text.string = "hello world\n"
        scroll.documentView = text

        scroll.contentView.scroll(to: NSPoint(x: -50, y: 0))
        #expect(scroll.contentView.bounds.origin.x == 0)

        scroll.contentView.setBoundsOrigin(NSPoint(x: -100, y: 0))
        #expect(scroll.contentView.bounds.origin.x == 0)

        scroll.contentView.scroll(to: NSPoint(x: 50, y: 0))
        #expect(scroll.contentView.bounds.origin.x == 50)

        scroll.contentView.setBoundsOrigin(NSPoint(x: 100, y: 0))
        #expect(scroll.contentView.bounds.origin.x == 100)

        let leadingConstrained = scroll.contentView.constrainBoundsRect(
            NSRect(x: -25, y: 0, width: 500, height: 400)
        )
        #expect(leadingConstrained.origin.x == 0)

        let validConstrained = scroll.contentView.constrainBoundsRect(
            NSRect(x: 75, y: 0, width: 500, height: 400)
        )
        #expect(validConstrained.origin.x == 75)

        let trailingConstrained = scroll.contentView.constrainBoundsRect(
            NSRect(x: 750, y: 0, width: 500, height: 400)
        )
        #expect(trailingConstrained.origin.x == 500)
    }

    @Test func coordinatorPathChangeClearsTextViewUndoStack() async throws {
        // Regression: NSTextView's undoManager survives across tab swaps
        // because CenterPaneView reuses the same text view. Without an
        // explicit removeAllActions on rebind, Undo would mutate the wrong
        // buffer's storage.
        let root = tempWorktree()
        _ = try writeFile(root, "a.swift", "let a = 1\n")
        _ = try writeFile(root, "b.swift", "let b = 2\n")
        let appState = AppState()
        let bufferA = appState.tabs.buffer(
            worktreeId: "wt", tabId: "tab-a",
            worktreeRoot: root, relativePath: "a.swift"
        )
        await bufferA.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        // NSTextView's undoManager comes from the responder chain; in this
        // headless test we don't have a window, so feed one in via a
        // delegate so the rebind path has something concrete to clear.
        let undoOwner = TestUndoOwner()
        textView.delegate = undoOwner
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current
        coordinator.attach(
            textView: textView, buffer: bufferA, layoutManager: layoutManager,
            worktreeId: "wt", worktreeRoot: root, tabId: "tab-a",
            revealLine: nil, revealCharacter: nil, theme: theme
        )

        // Stage an undoable action so canUndo flips on; payload is irrelevant.
        textView.undoManager?.registerUndo(withTarget: bufferA) { _ in }
        #expect(textView.undoManager?.canUndo == true)

        coordinator.updateIfNeeded(
            worktreeId: "wt", worktreeRoot: root,
            relativePath: "b.swift", tabId: "tab-b",
            revealLine: nil, revealCharacter: nil, theme: theme
        )

        #expect(textView.undoManager?.canUndo == false)
    }

    @Test func coordinatorDetachClearsTextViewUndoStack() async throws {
        // Regression: AppKit text undo actions target the NSTextView/TextKit
        // objects that created them. If SwiftUI tears down the editor while
        // those actions remain in the responder-chain undo manager, a later
        // Edit > Undo can send _undoRedoTextOperation: to stale objects.
        let root = tempWorktree()
        _ = try writeFile(root, "a.swift", "let a = 1\n")
        let appState = AppState()
        let buffer = appState.tabs.buffer(
            worktreeId: "wt", tabId: "tab-a",
            worktreeRoot: root, relativePath: "a.swift"
        )
        await buffer.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        let undoOwner = TestUndoOwner()
        textView.delegate = undoOwner
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current
        coordinator.attach(
            textView: textView, buffer: buffer, layoutManager: layoutManager,
            worktreeId: "wt", worktreeRoot: root, tabId: "tab-a",
            revealLine: nil, revealCharacter: nil, theme: theme
        )

        textView.undoManager?.registerUndo(withTarget: textView) { _ in }
        #expect(textView.undoManager?.canUndo == true)

        coordinator.detach()

        #expect(textView.undoManager?.canUndo == false)
    }
}

@MainActor
private final class TestUndoOwner: NSObject, NSTextViewDelegate {
    let undoManager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
}

@Suite("EditorBuffer.languageOverride")
@MainActor
struct EditorBufferLanguageOverrideTests {
    private func buffer(language: String?) async -> EditorBuffer {
        let buf = EditorBuffer(worktreeRoot: URL(fileURLWithPath: "/tmp/repo"), relativePath: "main.swift")
        await buf.awaitLoadForTesting()
        buf.setLanguageForTest(language)
        return buf
    }

    @Test func effectiveLanguageFallsBackToInferred() async {
        let buf = await buffer(language: "swift")
        #expect(buf.effectiveLanguage == "swift")
    }

    @Test func effectiveLanguageUsesOverrideWhenSet() async {
        let buf = await buffer(language: "swift")
        buf.languageOverride = "typescript"
        #expect(buf.effectiveLanguage == "typescript")
    }

    @Test func effectiveLanguageClearsBackToInferredOnNilOverride() async {
        let buf = await buffer(language: "swift")
        buf.languageOverride = "typescript"
        buf.languageOverride = nil
        #expect(buf.effectiveLanguage == "swift")
    }

    /// Verifies the reactive plumbing in `CodeEditorCoordinator`: when a tab
    /// flips its `languageOverride`, the coordinator's `observeEffectiveLanguage`
    /// observer should fire, update `currentLanguage`, and reapply the
    /// indentation mode. Checking `textView.indentationMode` is the cheapest
    /// visible side-effect to assert on (currentLanguage itself is private).
    @Test func coordinatorObserverRefreshesIndentationOnLanguageOverride() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-lsp-override-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("scratch.unknown")
        try "x\n".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let appState = AppState()
        let buffer = appState.tabs.buffer(
            worktreeId: "wt-override", tabId: "tab-override",
            worktreeRoot: root, relativePath: "scratch.unknown"
        )
        await buffer.awaitLoadForTesting()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 400, height: 300))
        layoutManager.addTextContainer(textContainer)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: textContainer)
        let coordinator = CodeEditorCoordinator(appState: appState)
        let theme = try ThemeStore().current

        coordinator.attach(
            textView: textView,
            buffer: buffer,
            layoutManager: layoutManager,
            worktreeId: "wt-override",
            worktreeRoot: root,
            tabId: "tab-override",
            revealLine: nil,
            revealCharacter: nil,
            theme: theme
        )
        // No registry entry for `.unknown` and no override → currentLanguage nil → plain.
        #expect(textView.indentationMode == .plain)

        buffer.languageOverride = "swift"

        // The override observer dispatches its updates through a `Task { @MainActor in }`
        // so we yield until the indentation flips (or the deadline trips).
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, textView.indentationMode != .bracketAware {
            await Task.yield()
        }
        #expect(textView.indentationMode == .bracketAware)
    }
}

private actor AsyncLoadGate {
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
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
