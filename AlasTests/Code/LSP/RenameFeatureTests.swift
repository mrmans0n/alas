import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
struct RenameFeatureTests {
    @Test(arguments: [false, true])
    func oversizedPreparationNeverCreatesPreviewOrJournal(tooManyTargets: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-edit-budget-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = WorkspaceEditJournal(root: root.appendingPathComponent("journal"))
        let tabs = TabsManager(tabsDirectory: root.appendingPathComponent("tabs"), workspaceEditJournal: journal)
        let origin = EditorDocumentID(host: nil, worktreeID: "w", uri: root.appendingPathComponent("origin").lspURI)
        let context = EditorRequestContext(document: origin, version: 1, serverGeneration: UUID(), range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0)))
        var changes: [LSPDocumentChange] = []
        for index in 0..<(tooManyTargets ? 257 : 5) {
            let file = root.appendingPathComponent("target-\(index)")
            if !tooManyTargets {
                #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: 16 * 1024 * 1024)
                try handle.close()
            }
            changes.append(tooManyTargets ? .create(uri: file.lspURI, options: .init(), annotationID: nil) : .delete(uri: file.lspURI, options: .init(), annotationID: nil))
        }
        let view = CodeTextView(frame: .zero, textContainer: nil)
        let feature = RenameFeature(textView: view, tabs: tabs, root: root, synchronize: { _ in nil }, isCurrent: { $0 == context })
        do {
            _ = try await feature.prepare(.init(documentChanges: changes), context: context, generations: [:])
            Issue.record("Over-budget operation must be refused before preview")
        } catch {
            #expect(error.localizedDescription.contains(tooManyTargets ? "256" : "64 MiB"))
        }
        #expect(try journal.records().isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("target-0").path) == !tooManyTargets)
    }

    @Test(arguments: [
        #"{"start":{"line":0,"character":4},"end":{"line":0,"character":7}}"#,
        #"{"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":7}},"placeholder":"old"}"#,
        #"{"defaultBehavior":true}"#
    ])
    func prepareVariants(_ json: String) async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { _ in transport.deliverFrame("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(json)}") }
        let result = try await client.prepareRename(uri: "file:///tmp/a.swift", position: .init(line: 0, character: 5))
        let prepared = try RenameFeature.preparedSymbol(result, text: "let old = 1", fallbackRange: NSRange(location: 4, length: 3))
        #expect(prepared.name == "old")
        #expect(prepared.range == NSRange(location: 4, length: 3))
    }

    @Test func nullPreparationRejectsRename() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { _ in transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":null}"#) }
        let result = try await client.prepareRename(uri: "file:///tmp/a.swift", position: .init(line: 0, character: 0))
        #expect(throws: (any Error).self) {
            try RenameFeature.preparedSymbol(result, text: "old", fallbackRange: NSRange(location: 0, length: 3))
        }
    }

    @Test func renameNullMeansNoEdits() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            #expect(sent.contains("textDocument/rename"))
            #expect(sent.contains("newName"))
            transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":null}"#)
        }
        #expect(try await client.rename(uri: "file:///tmp/a.swift", position: .init(line: 0, character: 0), newName: "new") == nil)
    }

    @Test func indentationMatchesEditor() {
        #expect(RenameFeature.formattingOptions(text: "x\n  y").tabSize == 2)
        #expect(RenameFeature.formattingOptions(text: "x\n\ty").insertSpaces == false)
    }

    @Test func prepareCapabilityAndRangeFormatting() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                #expect(sent.contains(#""prepareSupport":true"#))
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"renameProvider":{"prepareProvider":true},"documentRangeFormattingProvider":true}}}"#)
            } else if sent.contains("textDocument/rangeFormatting") {
                #expect(sent.contains(#""tabSize":2"#))
                #expect(sent.contains(#""insertSpaces":false"#))
                #expect(sent.contains(#""line":3"#))
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":2,"result":[]}"#)
            }
        }
        try await client.initialize()
        #expect(await client.supportsPrepareRename)
        let edits = try await client.rangeFormatting(uri: "file:///tmp/a.swift", range: .init(start: .init(line: 3, character: 0), end: .init(line: 4, character: 0)), options: .init(tabSize: 2, insertSpaces: false))
        #expect(edits.isEmpty)
    }

    @Test func serverRejectionKeepsItsMessage() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { _ in transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Symbol belongs to a dependency"}}"#) }
        do {
            _ = try await client.prepareRename(uri: "file:///tmp/a.swift", position: .init(line: 0, character: 0))
            Issue.record("Expected server rejection")
        } catch {
            #expect(RenameFeature.message(for: error) == "Symbol belongs to a dependency")
        }
    }

    @Test func defaultFalseAndMalformedRangeReject() {
        #expect(throws: (any Error).self) {
            try RenameFeature.preparedSymbol(.defaultBehavior(false), text: "old", fallbackRange: NSRange(location: 0, length: 3))
        }
        #expect(throws: (any Error).self) {
            try RenameFeature.preparedSymbol(.range(.init(start: .init(line: 0, character: 2), end: .init(line: 0, character: 1)), placeholder: nil), text: "old", fallbackRange: NSRange(location: 0, length: 3))
        }
    }

    @Test func explicitFormattingChangesBufferWithoutSavingAndArmsSharedUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-format-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.swift")
        let original = "let x=1\n  x"
        try Data(original.utf8).write(to: file)
        let transport = FakeTransport()
        defer { transport.finish() }
        transport.onSend = { sent in
            guard let json = try? JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any],
                  let method = json["method"] as? String, let id = json["id"] as? Int else { return }
            if method == "initialize" {
                transport.deliverFrame("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"capabilities\":{\"documentFormattingProvider\":true}}}")
            } else if method == "textDocument/formatting" {
                #expect(sent.contains(#""tabSize":2"#))
                transport.deliverFrame("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":7}},\"newText\":\"let x = 1\"}]}")
            }
        }
        let lsp = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: [
            LanguageServerConfig(language: "swift", extensions: ["swift"], command: "/usr/bin/true", args: [], env: [:], rootMarkers: [], enabled: true)
        ]), makeClient: { _, _, _, language, rootURI in LSPClient(transport: transport, language: language, rootURI: rootURI) })
        let journal = WorkspaceEditJournal(root: root.appendingPathComponent("journal"))
        let tabs = TabsManager(lsp: lsp, tabsDirectory: root.appendingPathComponent("tabs"), workspaceEditJournal: journal)
        let tab = tabs.openEditor(worktreeId: "w", relativePath: "a.swift", revealLine: nil, revealCharacter: nil)
        let buffer = tabs.buffer(worktreeId: "w", tabId: tab.id, worktreeRoot: root, relativePath: "a.swift")
        defer { buffer.close(persistDirtySnapshot: false) }
        await buffer.awaitLoadForTesting()
        await buffer.awaitWorkspaceEditLifecycle()
        buffer.stopWatching()
        let binding = EditorLSPBinding(manager: lsp, buffer: buffer, worktreeID: "w")
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layout.addTextContainer(container)
        buffer.storage.addLayoutManager(layout)
        let view = CodeTextView(frame: .zero, textContainer: container)
        let feature = RenameFeature(textView: view, tabs: tabs, root: root,
                                    synchronize: { await binding.synchronizeRequest(range: $0, language: "swift") },
                                    isCurrent: { binding.isCurrent($0) })
        feature.format(range: NSRange(location: 0, length: 0), selectionOnly: false)
        await feature.awaitRequestForTesting()
        #expect(buffer.storage.string == "let x = 1\n  x")
        #expect(buffer.dirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        #expect(buffer.undoManager.canUndo)
        let operation = try #require(journal.records().first(where: { $0.status == .applied }))
        let undo = tabs.workspaceEditUndoCoordinator(forWorktreeId: "w", worktreeRoot: root)
        guard case .applied = await undo.undo(operationID: operation.id) else {
            Issue.record("Expected explicit formatting to register shared undo")
            return
        }
        #expect(buffer.storage.string == original)
    }

    @Test(arguments: [false, true])
    func unopenedPreviewTargetsHaveNormalUndoInInitiatingEditor(resourceOnly: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-undo-owner-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originURL = root.appendingPathComponent("origin.txt")
        let targetURL = root.appendingPathComponent("target.txt")
        let movedURL = root.appendingPathComponent("moved.txt")
        try Data("origin".utf8).write(to: originURL)
        try Data("old".utf8).write(to: targetURL)
        let journal = WorkspaceEditJournal(root: root.appendingPathComponent("journal"))
        let tabs = TabsManager(tabsDirectory: root.appendingPathComponent("tabs"), workspaceEditJournal: journal)
        let tab = tabs.openEditor(worktreeId: "w", relativePath: "origin.txt", revealLine: nil, revealCharacter: nil)
        let buffer = tabs.buffer(worktreeId: "w", tabId: tab.id, worktreeRoot: root, relativePath: "origin.txt")
        defer { buffer.close(persistDirtySnapshot: false) }
        await buffer.awaitLoadForTesting()
        buffer.stopWatching()
        let origin = EditorDocumentID(host: nil, worktreeID: "w", uri: originURL.lspURI)
        let target = EditorDocumentID(host: nil, worktreeID: "w", uri: targetURL.lspURI)
        let moved = EditorDocumentID(host: nil, worktreeID: "w", uri: movedURL.lspURI)
        let context = EditorRequestContext(document: origin, version: 1, serverGeneration: UUID(), range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 0)))
        let access = HostWorkspaceEditFileAccess(tabs: tabs, rootForDocument: { _ in root })
        let changes: [LSPDocumentChange] = resourceOnly
            ? [.rename(oldURI: target.uri, newURI: moved.uri, options: .init(), annotationID: nil)]
            : [.textDocument(document: .init(uri: target.uri, version: nil), edits: [.init(range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 3)), newText: "new")])]
        let targetSnapshot = try await access.snapshot(target)
        let movedSnapshot = try await access.snapshot(moved)
        let plan = try WorkspaceEditPlanner.plan(edit: .init(documentChanges: changes), context: context, snapshots: [
            target: targetSnapshot, moved: movedSnapshot
        ])
        #expect(plan.requiresPreview)
        #expect(tabs.workspaceEditBuffer(for: target) == nil)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layout.addTextContainer(container)
        buffer.storage.addLayoutManager(layout)
        let view = CodeTextView(frame: .zero, textContainer: container)
        view.bindUndo(to: buffer)
        let feature = RenameFeature(textView: view, tabs: tabs, root: root, synchronize: { _ in nil }, isCurrent: { $0 == context })
        let model = feature.makePreviewModel(plan: plan, context: context)
        #expect(await model.apply())
        #expect(try String(contentsOf: resourceOnly ? movedURL : targetURL, encoding: .utf8) == (resourceOnly ? "old" : "new"))
        #expect(buffer.storage.string == "origin")
        #expect(!buffer.dirty)
        try #require(buffer.undoManager.canUndo)
        #expect(view.tryToPerform(NSSelectorFromString("undo:"), with: nil))
        let undo = tabs.workspaceEditUndoCoordinator(forWorktreeId: "w", worktreeRoot: root)
        for _ in 0..<200 {
            if undo.lastOutcome != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .applied = undo.lastOutcome else { Issue.record("Expected normal Undo to restore the unopened target")
        return }
        #expect(try String(contentsOf: targetURL, encoding: .utf8) == "old")
        #expect(!FileManager.default.fileExists(atPath: movedURL.path))
        #expect(buffer.undoManager.canRedo)
        #expect(try journal.records().filter { $0.status == .applied }.count == 2)
        #expect(!buffer.undoManager.canUndo)
    }
}
