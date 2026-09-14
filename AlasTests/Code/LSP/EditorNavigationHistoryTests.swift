import Foundation
import Testing
@testable import Alas

@Suite("Editor navigation history")
struct EditorNavigationHistoryTests {
    private let document = EditorDocumentID(host: nil, worktreeID: "w", uri: "file:///a.swift")

    @Test @MainActor func backReturnsSource() {
        let store = EditorNavigationStore()
        let a = target(line: 0)
        let b = target(line: 8)

        store.recordJump(from: a, to: b)

        #expect(store.goBack() == a)
        #expect(store.goForward() == b)
    }

    @Test @MainActor func successfulJumpAfterBackTruncatesForwardHistory() {
        let store = EditorNavigationStore()
        let a = target(line: 0)
        let b = target(line: 8)
        let c = target(line: 16)

        store.recordJump(from: a, to: b)
        store.recordJump(from: b, to: c)
        #expect(store.goBack() == b)

        store.recordJump(from: b, to: a)

        #expect(store.goForward() == nil)
        #expect(store.goBack() == b)
    }

    @Test @MainActor func duplicateJumpDoesNotCreateAHistoryEntry() {
        let store = EditorNavigationStore()
        let a = target(line: 0)
        let b = target(line: 8)

        store.recordJump(from: a, to: b)
        store.recordJump(from: b, to: b)

        #expect(store.goBack() == a)
        #expect(store.goBack() == nil)
    }

    @Test @MainActor func unavailableTargetRemainsInHistoryUntilActivationSucceeds() {
        let store = EditorNavigationStore()
        let a = target(line: 0)
        let unavailable = target(line: 8)

        store.recordJump(from: a, to: unavailable)
        store.recordActivationFailure(for: unavailable)

        #expect(store.goBack() == a)
        #expect(store.goForward() == unavailable)
        #expect(store.statusMessage == "Could not open navigation target")
    }

    @Test @MainActor func failedBackActivationRestoresTheCurrentHistoryLocation() {
        let store = EditorNavigationStore()
        let a = target(line: 0)
        let b = target(line: 8)

        store.recordJump(from: a, to: b)
        #expect(store.goBack() == a)
        store.recordActivationFailure(for: a)

        #expect(store.goForward() == nil)
        #expect(store.goBack() == a)
    }

    @Test @MainActor func failedHostQualifiedActivationKeepsCurrentHistoryLocation() {
        let store = EditorNavigationStore()
        let unavailable = EditorNavigationTarget(
            document: EditorDocumentID(host: "other-host", worktreeID: "w", uri: "file:///tmp/unavailable.swift"),
            position: LSPPosition(line: 0, character: 0)
        )
        let current = target(line: 8)
        store.recordJump(from: unavailable, to: current)

        #expect(store.goBack() == unavailable)
        let didOpen = TabsManager().openNavigationTarget(
            unavailable,
            worktreeRoot: URL(fileURLWithPath: "/tmp/navigation-history"),
            originatingRelativePath: nil,
            language: "swift"
        )
        #expect(!didOpen)
        store.recordActivationFailure(for: unavailable)

        #expect(store.goForward() == nil)
        #expect(store.goBack() == unavailable)
    }

    @Test @MainActor func historiesAreIndependentForEachWorktreeStore() {
        let first = EditorNavigationStore()
        let second = EditorNavigationStore()
        let a = target(line: 0)
        let b = target(line: 8)

        first.recordJump(from: a, to: b)

        #expect(second.goBack() == nil)
        #expect(first.goBack() == a)
    }

    @Test(arguments: [
        ("root", "root/sub/../../outside%20%25%20file.swift", "outside % file.swift", nil as String?),
        ("root", "outside%20%25%20file.swift", "outside % file.swift", nil),
        ("root", "rootish/sibling.swift", "rootish/sibling.swift", nil),
        ("root", "root/sub/../inside%20%25%20file.swift", "root/inside % file.swift", "inside % file.swift"),
        ("root/sub/..", "root/inside%20%25%20file.swift", "root/inside % file.swift", "inside % file.swift"),
        ("root", "root/inside%20%25%20file.swift", "root/inside % file.swift", "inside % file.swift"),
        ("root", "root/link/file.swift", "outside/file.swift", nil),
        ("root", "root/internal/file.swift", "root/sub/file.swift", "internal/file.swift"),
        ("root-alias", "root-alias/link/file.swift", "outside/file.swift", nil),
        ("root-alias", "root-alias/internal/file.swift", "root/sub/file.swift", "internal/file.swift")
    ])
    @MainActor func navigationContainmentControlsBufferAndSaveRoute(
        rootPath: String,
        targetPath: String,
        diskPath: String,
        expectedRelativePath: String?
    ) async throws {
        try await checkNavigationContainment(
            rootPath: rootPath, targetPath: targetPath, diskPath: diskPath,
            expectedRelativePath: expectedRelativePath
        )
    }

    @Test(arguments: [
        ("root/link/missing.swift", "outside/missing.swift"),
        ("root/dangling/file.swift", "absent/file.swift")
    ])
    @MainActor func missingSymlinkNavigationStaysExternalAndCannotSave(targetPath: String, diskPath: String) async throws {
        try await checkNavigationContainment(
            rootPath: "root", targetPath: targetPath, diskPath: diskPath,
            expectedRelativePath: nil, missing: true
        )
    }

    @Test(arguments: [false, true])
    @MainActor func retargetedNavigationDirectoryCannotSaveOutsideWorktree(outsideFileExists: Bool) async throws {
        try await checkRetargetedNavigationSave(retargetRoot: false, outsideFileExists: outsideFileExists)
    }

    @Test @MainActor func retargetedNavigationRootCannotSaveOutsideOriginalWorktree() async throws {
        try await checkRetargetedNavigationSave(retargetRoot: true, outsideFileExists: false)
    }

    @Test(arguments: [false, true], [false, true])
    @MainActor func navigationTrustSurvivesLazyBufferCreation(retargetRoot: Bool, restoreTabs: Bool) async throws {
        try await checkLazyNavigationRetarget(retargetRoot: retargetRoot, restoreTabs: restoreTabs)
    }

    @Test @MainActor func navigationTrustProtectsSnapshotOnlySaveAfterRootRetarget() async throws {
        try await checkLazyNavigationRetarget(retargetRoot: true, restoreTabs: true, snapshotOnlySave: true)
    }

    @Test(arguments: [false, true])
    @MainActor func restoredNavigationDraftRemainsReadOnlyAfterRetarget(retargetRoot: Bool) async throws {
        try await checkLazyNavigationRetarget(retargetRoot: retargetRoot, restoreTabs: true, restoreDraft: true)
    }

    @MainActor private func checkLazyNavigationRetarget(retargetRoot: Bool, restoreTabs: Bool, snapshotOnlySave: Bool = false, restoreDraft: Bool = false) async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("navigation-lazy-retarget-\(UUID())", isDirectory: true)
        let originalDirectory = fixture.appendingPathComponent("root/sub", isDirectory: true)
        let outsideDirectory = fixture.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let originalFile = originalDirectory.appendingPathComponent("file.swift")
        let outsideFile = outsideDirectory.appendingPathComponent("file.swift")
        try Data("original".utf8).write(to: originalFile)
        try Data("outside".utf8).write(to: outsideFile)
        let link = fixture.appendingPathComponent(retargetRoot ? "root-alias" : "root/internal", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: originalDirectory)
        let root = retargetRoot ? link : fixture.appendingPathComponent("root", isDirectory: true)
        let store = EditorBufferStore(rootOverride: fixture.appendingPathComponent("buffers"))
        let tabsDirectory = fixture.appendingPathComponent("tabs")
        var manager = TabsManager(bufferStore: store, tabsDirectory: tabsDirectory)
        let target = EditorNavigationTarget(
            document: EditorDocumentID(host: nil, worktreeID: "w", uri: link.appendingPathComponent("file.swift").absoluteString),
            position: LSPPosition(line: 0, character: 0)
        )
        #expect(manager.openNavigationTarget(target, worktreeRoot: root, originatingRelativePath: nil, language: "swift"))
        if restoreTabs {
            manager = TabsManager(bufferStore: store, tabsDirectory: tabsDirectory)
            manager.loadAll(worktreeIds: ["w"])
        }
        guard case .editor(let state) = try #require(manager.activeTab(forWorktree: "w")) else {
            Issue.record("Navigation did not open an editor")
            return
        }
        #expect(manager.peekBuffer(tabId: state.id) == nil)
        if snapshotOnlySave || restoreDraft {
            let mtime = try #require(FileManager.default.attributesOfItem(atPath: outsideFile.path)[.modificationDate] as? Date)
            try store.write(.init(relativePath: state.relativePath, content: "draft", originalText: "original", originalMtime: mtime, lineEnding: .lf), worktreeId: "w", tabId: state.id)
        }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory)

        if snapshotOnlySave {
            let errors = manager.saveAll(worktreeRoots: ["w": root])
            #expect(errors.count == 1)
            #expect(try String(contentsOf: originalFile, encoding: .utf8) == "original")
            #expect(try String(contentsOf: outsideFile, encoding: .utf8) == "outside")
            #expect(try store.read(worktreeId: "w", tabId: state.id)?.content == "draft")
            return
        }

        let buffer = manager.buffer(worktreeId: "w", tabId: state.id, worktreeRoot: root, relativePath: state.relativePath)
        defer { manager.discardBuffer(worktreeId: "w", tabId: state.id) }
        await buffer.awaitLoadForTesting()
        buffer.stopWatching()
        #expect(buffer.readOnly)
        #expect(!buffer.acceptsSourceInput)
        if restoreDraft {
            #expect(buffer.storage.string == "draft")
            #expect(buffer.dirty)
            try? buffer.saveAs(relativePath: "copy.swift")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("copy.swift").path))
            try? buffer.moveTo(relativePath: "moved.swift")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("moved.swift").path))
            buffer.snapshotNow()
            #expect(try store.read(worktreeId: "w", tabId: state.id)?.content == "draft")
            #expect(throws: (any Error).self) { try buffer.save() }
            #expect(manager.saveAll(worktreeRoots: ["w": root]).count == 1)
            #expect(try String(contentsOf: outsideFile, encoding: .utf8) == "outside")
            return
        }
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: buffer.storage.length), with: "changed")
        // A read-only buffer may no-op; a retained save boundary may refuse.
        try? buffer.save()
        #expect(try String(contentsOf: originalFile, encoding: .utf8) == "original")
        #expect(try String(contentsOf: outsideFile, encoding: .utf8) == "outside")
    }

    @MainActor private func checkRetargetedNavigationSave(retargetRoot: Bool, outsideFileExists: Bool) async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("navigation-retarget-\(UUID())", isDirectory: true)
        let originalDirectory = fixture.appendingPathComponent("root/sub", isDirectory: true)
        let outsideDirectory = fixture.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = originalDirectory.appendingPathComponent("file.swift")
        let outsideFile = outsideDirectory.appendingPathComponent("file.swift")
        try Data("original".utf8).write(to: file)
        if outsideFileExists {
            try Data("outside".utf8).write(to: outsideFile)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: outsideFile.path)
        }
        let link = fixture.appendingPathComponent(retargetRoot ? "root-alias" : "root/internal", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: originalDirectory)
        let root = retargetRoot ? link : fixture.appendingPathComponent("root", isDirectory: true)
        let logicalFile = link.appendingPathComponent("file.swift")
        let manager = TabsManager(
            bufferStore: EditorBufferStore(rootOverride: fixture.appendingPathComponent("buffers")),
            tabsDirectory: fixture.appendingPathComponent("tabs")
        )
        let target = EditorNavigationTarget(
            document: EditorDocumentID(host: nil, worktreeID: "w", uri: logicalFile.absoluteString),
            position: LSPPosition(line: 0, character: 0)
        )
        #expect(manager.openNavigationTarget(target, worktreeRoot: root, originatingRelativePath: nil, language: "swift"))
        guard case .editor(let state) = try #require(manager.activeTab(forWorktree: "w")) else {
            Issue.record("Navigation did not open an editor")
            return
        }
        #expect(state.externalAbsolutePath == nil)
        let buffer = manager.buffer(worktreeId: "w", tabId: state.id, worktreeRoot: root, relativePath: state.relativePath)
        defer { manager.discardBuffer(worktreeId: "w", tabId: state.id) }
        await buffer.awaitLoadForTesting()
        buffer.stopWatching()
        #expect(!buffer.readOnly)
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: buffer.storage.length), with: "changed")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory)

        do {
            try buffer.save()
            Issue.record("Saving through a retargeted directory must fail")
        } catch {
            #expect(buffer.dirty)
        }

        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        if outsideFileExists {
            #expect(try String(contentsOf: outsideFile, encoding: .utf8) == "outside")
        } else {
            #expect(!FileManager.default.fileExists(atPath: outsideFile.path))
        }
        #expect(buffer.storage.string == "changed")
        #expect(buffer.dirty)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: originalDirectory)
        buffer.resolveConflictKeepingMine()
        try buffer.save()
        #expect(try String(contentsOf: file, encoding: .utf8) == "changed")
        #expect(!buffer.dirty)
    }

    @MainActor private func checkNavigationContainment(
        rootPath: String,
        targetPath: String,
        diskPath: String,
        expectedRelativePath: String?,
        missing: Bool = false
    ) async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("navigation-containment-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("root/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("rootish"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("outside"), withIntermediateDirectories: true)
        for (link, destination) in [
            ("root/link", "outside"), ("root/internal", "root/sub"),
            ("root-alias", "root"), ("root/dangling", "absent")
        ] {
            try FileManager.default.createSymbolicLink(
                at: fixture.appendingPathComponent(link), withDestinationURL: fixture.appendingPathComponent(destination)
            )
        }
        let file = fixture.appendingPathComponent(diskPath)
        if !missing { try Data("original".utf8).write(to: file) }
        let root = try #require(URL(string: fixture.absoluteString + rootPath))
        let target = EditorNavigationTarget(
            document: EditorDocumentID(host: nil, worktreeID: "w", uri: fixture.absoluteString + targetPath),
            position: LSPPosition(line: 3, character: 7)
        )
        let manager = TabsManager(
            bufferStore: EditorBufferStore(rootOverride: fixture.appendingPathComponent("buffers")),
            tabsDirectory: fixture.appendingPathComponent("tabs")
        )

        #expect(manager.openNavigationTarget(target, worktreeRoot: root, originatingRelativePath: "source.swift", language: "swift"))
        let tab = try #require(manager.activeTab(forWorktree: "w"))
        guard case .editor(let state) = tab else {
            Issue.record("Navigation did not open an editor")
            return
        }
        defer { manager.discardBuffer(worktreeId: "w", tabId: state.id) }
        #expect(state.relativePath == (expectedRelativePath ?? ""))
        let logicalTarget = try #require(URL(string: target.document.uri)).standardizedFileURL
        #expect(state.externalAbsolutePath == (expectedRelativePath == nil ? logicalTarget.path : nil))
        #expect(!state.isExternalEditable)
        #expect(state.revealLine == 3)
        #expect(state.revealCharacter == 7)

        // Follow the same tab-state branch used by the mounted editor.
        let buffer: EditorBuffer
        if let absolutePath = state.externalAbsolutePath {
            buffer = manager.externalBuffer(worktreeId: "w", tabId: state.id, absoluteURL: URL(fileURLWithPath: absolutePath))
        } else {
            buffer = manager.buffer(worktreeId: "w", tabId: state.id, worktreeRoot: root, relativePath: state.relativePath)
        }
        await buffer.awaitLoadForTesting()
        buffer.stopWatching()
        #expect(buffer.storage.string == (missing ? "(unable to read file)" : "original"))
        #expect(buffer.isExternal == (expectedRelativePath == nil))
        #expect(buffer.readOnly == (expectedRelativePath == nil))
        #expect((manager.activeEditorContext(worktreeId: "w") == nil) == (expectedRelativePath == nil))
        #expect((manager.peekExternalBuffer(tabId: state.id) != nil) == (expectedRelativePath == nil))
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: buffer.storage.length), with: "changed")
        try buffer.save()
        if missing {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        } else {
            #expect(try String(contentsOf: file, encoding: .utf8) == (expectedRelativePath == nil ? "original" : "changed"))
        }
    }

    @Test @MainActor func historyKeepsOnlyTheMostRecentTwoHundredLocations() {
        let store = EditorNavigationStore()
        var previous = target(line: 0)
        for line in 1 ... 200 {
            let next = target(line: line)
            store.recordJump(from: previous, to: next)
            previous = next
        }

        var firstReachable: EditorNavigationTarget?
        while let target = store.goBack() {
            firstReachable = target
        }

        #expect(firstReachable == target(line: 1))
    }

    @Test @MainActor func editedReferenceResultsStayBrowsableAndBecomeStale() {
        let store = EditorNavigationStore()
        let result = target(line: 8)

        store.replaceResults([result])
        store.markResultsStale()

        #expect(store.results == [result])
        #expect(store.resultsAreStale)
    }

    private func target(line: Int) -> EditorNavigationTarget {
        EditorNavigationTarget(document: document, position: LSPPosition(line: line, character: 0))
    }
}
