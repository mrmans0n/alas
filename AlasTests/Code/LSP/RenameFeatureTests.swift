import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
struct RenameFeatureTests {
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
}
