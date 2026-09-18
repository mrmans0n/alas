import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct EditorDisplayIntegrationTests {
    @Test func reusedCoordinatorRebindsCaptureMutationRootAndExternalRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mounted-binding-\(UUID())")
        let firstRoot = directory.appendingPathComponent("first")
        let nextRoot = directory.appendingPathComponent("second")
        for root in [firstRoot, nextRoot] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("value".utf8).write(to: root.appendingPathComponent("file.swift"))
        }
        let external = directory.appendingPathComponent("external.swift")
        try Data("value".utf8).write(to: external)
        var transports: [FakeTransport] = []
        var externalMethods = Set<String>()
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: [LanguageServerConfig(language: "swift", extensions: ["swift"], command: "/usr/bin/true", args: [], env: [:], rootMarkers: [], enabled: true)]), makeClient: { _, _, _, language, uri in
            let transport = FakeTransport()
            transports.append(transport)
            transport.onSend = { sent in
                Task { @MainActor in
                    guard let request = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = request["id"] else { return }
                    let method = request["method"]?.stringValue ?? ""
                    if request["params"]?["textDocument"]?["uri"] == .string(external.lspURI) { externalMethods.insert(method) }
                    let result: LSPJSONValue
                    switch method {
                    case "initialize": result = .object(["capabilities": .object(["hoverProvider": .bool(true), "definitionProvider": .bool(true), "documentFormattingProvider": .bool(true)])])
                    case "textDocument/formatting": result = .array([Self.edit(line: 0, start: 0, end: 5, text: "formatted")])
                    case "textDocument/definition": result = .array([])
                    default: result = .null
                    }
                    transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["id": id, "result": result]).encodedData(), as: UTF8.self))
                }
            }
            return LSPClient(transport: transport, language: language, rootURI: uri)
        })
        let tabs = TabsManager(bufferStore: EditorBufferStore(rootOverride: directory.appendingPathComponent("buffers")), lsp: manager, tabsDirectory: directory.appendingPathComponent("tabs"), workspaceEditJournal: WorkspaceEditJournal(root: directory.appendingPathComponent("journal")))
        let app = AppState(tabsManager: tabs, lspManager: manager)
        let first = tabs.buffer(worktreeId: "first", tabId: "first", worktreeRoot: firstRoot, relativePath: "file.swift")
        let next = tabs.buffer(worktreeId: "next", tabId: "next", worktreeRoot: nextRoot, relativePath: "file.swift")
        await first.awaitLoadForTesting()
        await next.awaitLoadForTesting()
        await first.awaitWorkspaceEditLifecycle()
        await next.awaitWorkspaceEditLifecycle()
        first.stopWatching()
        next.stopWatching()
        let layout = CodeEditorLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 800, height: 600))
        layout.addTextContainer(container)
        let view = CodeTextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        let window = NSWindow(contentRect: view.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        let coordinator = CodeEditorCoordinator(appState: app)
        let theme = try ThemeStore().current
        coordinator.attach(textView: view, buffer: first, layoutManager: layout, worktreeId: "first", worktreeRoot: firstRoot, tabId: "first", revealLine: nil, revealCharacter: nil, theme: theme)
        defer {
            coordinator.detach()
            window.orderOut(nil)
            window.contentView = nil
            first.close(persistDirtySnapshot: false)
            next.close(persistDirtySnapshot: false)
            transports.forEach { $0.finish() }
            try? FileManager.default.removeItem(at: directory)
        }
        let oldBinding: EditorLSPBinding = try #require(Self.stored("lspBinding", in: coordinator))
        let old = try #require(await oldBinding.synchronizeRequest(range: .init(location: 0, length: 0), language: "swift"))
        coordinator.updateIfNeeded(worktreeId: "next", worktreeRoot: nextRoot, relativePath: "file.swift", tabId: "next", revealLine: nil, revealCharacter: nil, theme: theme)
        let binding: EditorLSPBinding = try #require(Self.stored("lspBinding", in: coordinator))
        #expect(manager.isCurrent(old.1))
        #expect(!binding.isCurrent(old.1))
        #expect(!oldBinding.isCurrent(old.1))
        let captured = try #require(await binding.synchronizeRequest(range: .init(location: 0, length: 0), language: "swift"))
        view.insertText("x", replacementRange: NSRange(location: 0, length: 1))
        #expect(!binding.isCurrent(captured.1))
        let rename: RenameFeature = try #require(Self.stored("renameFeature", in: coordinator))
        rename.format(range: .init(location: 0, length: 0), selectionOnly: false)
        await rename.awaitRequestForTesting()
        #expect(next.storage.string == "formatted")
        #expect(first.storage.string == "value")
        coordinator.updateIfNeeded(worktreeId: "next", worktreeRoot: nextRoot, relativePath: "external.swift", tabId: "external", revealLine: nil, revealCharacter: nil, theme: theme, externalAbsolutePath: external.path, originatingRelativePath: "file.swift")
        try await Self.eventually { manager.isDocumentOpen(fileURL: external, worktreeRoot: nextRoot) }
        view.triggerCommandClick(atUTF16Offset: 1)
        view.triggerHover(atUTF16Offset: 1)
        try await Self.eventually { externalMethods.contains("textDocument/definition") && externalMethods.contains("textDocument/hover") }
        #expect(!view.isEditable)
        tabs.discardBuffer(worktreeId: "next", tabId: "external")
    }

    @Test("pending server request does not block native typing or menu")
    func twoSecondServerDelayDoesNotBlockNativeTypingOrMenu() async throws {
        let fixture = try await Fixture(String(repeating: "let value = 1\n", count: 10000))
        defer { fixture.remove() }
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        var replied = false
        var reply: (() -> Void)?
        transport.onSend = { sent in
            guard let request = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = request["id"] else { return }
            Task { @MainActor in
                // `Thread.isMainThread` is unavailable from async contexts; the
                // enclosing `@MainActor` closure already carries the guarantee, and
                // this asserts it at runtime the same way.
                MainActor.assertIsolated()
                reply = {
                    transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": .null]).encodedData(), as: UTF8.self))
                    replied = true
                }
            }
        }
        let request = Task { try await client.hover(uri: "file:///tmp/file.swift", position: .init(line: 0, character: 0)) }
        defer { request.cancel() }
        try await Self.eventually("pending hover request") { reply != nil }
        let router = EditorCommandRouter(capabilities: .init(supportedCommands: [.hover]), isServerReady: true, handlers: [.hover: { _ in }])
        fixture.view.editorCommandRouter = router
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 4, y: 4), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        fixture.view.setSourceSelectedRange(NSRange(location: 0, length: 0))
        fixture.view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        let menu = fixture.view.menu(for: event)
        #expect(fixture.buffer.storage.string.hasPrefix("xlet value"))
        #expect(menu?.items.contains { $0.title == "Show Hover" } == true)
        #expect(!replied)
        let sendReply = try #require(reply)
        sendReply()
        _ = try await request.value
        #expect(replied)
        let snippets = EditorNavigationStore()
        let targets = (0..<20).map { line in
            EditorNavigationTarget(document: .init(host: nil, worktreeID: "large", uri: fixture.root.appendingPathComponent("test.txt").lspURI), position: .init(line: line * 400, character: 0))
        }
        let snippetStart = ContinuousClock.now
        snippets.replaceResults(targets)
        for target in targets { snippets.loadSnippet(for: target) }
        try await Self.eventually("large-file reference snippets") { snippets.snippets.count == 20 }
        #expect(snippets.snippets.values.allSatisfy { $0 == "let value = 1" })
        print("EDITOR_LSP_SNIPPETS fileBytes=140000 targets=20 elapsed=\(snippetStart.duration(to: .now))")
    }

    @Test func mountedInlayEditUsesPreviewExecutorAndGuardedUndo() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        let transport = FakeTransport()
        transport.onSend = { sent in
            guard let request = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = request["id"] else { return }
            let result: LSPJSONValue
            switch request["method"]?.stringValue {
            case "initialize": result = .object(["capabilities": .object(["inlayHintProvider": .bool(true)])])
            case "textDocument/inlayHint":
                result = .array([.object([
                    "position": .object(["line": .number("0"), "character": .number("9")]),
                    "label": .string(": Int"),
                    "textEdits": .array([Self.edit(line: 0, start: 9, end: 9, text: ": Int")])
                ])])
            default: result = .null
            }
            transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).encodedData(), as: UTF8.self))
        }
        let client = LSPClient(transport: transport, language: "swift", rootURI: root.lspURI)
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: [LanguageServerConfig(language: "swift", extensions: ["swift"], command: "/usr/bin/true", args: [], env: [:], rootMarkers: [], enabled: true)]), makeClient: { _, _, _, _, _ in client })
        let tabs = TabsManager(bufferStore: EditorBufferStore(rootOverride: root.appendingPathComponent("buffers")), lsp: manager, tabsDirectory: root.appendingPathComponent("tabs"), workspaceEditJournal: WorkspaceEditJournal(root: root.appendingPathComponent("journal")))
        let app = AppState(tabsManager: tabs, lspManager: manager)
        app.config.code.inlayHints = .init()
        app.config.code.inlayHintsByLanguage = [:]
        let buffer = tabs.buffer(worktreeId: "inlay-action", tabId: "tab", worktreeRoot: root, relativePath: "file.swift")
        await buffer.awaitLoadForTesting()
        await buffer.awaitWorkspaceEditLifecycle()
        buffer.stopWatching()
        let layout = CodeEditorLayoutManager(), container = NSTextContainer(size: CGSize(width: 800, height: 600))
        layout.addTextContainer(container)
        let view = CodeTextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        let window = NSWindow(contentRect: view.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        let coordinator = CodeEditorCoordinator(appState: app)
        coordinator.attach(textView: view, buffer: buffer, layoutManager: layout, worktreeId: "inlay-action", worktreeRoot: root, tabId: "tab", revealLine: nil, revealCharacter: nil, theme: try ThemeStore().current)
        defer {
            coordinator.detach()
            window.orderOut(nil)
            window.contentView = nil
            buffer.close(persistDirtySnapshot: false)
            transport.finish()
        }
        try await Self.eventually("mounted inlay") { view.displayAdapter?.document.map.hintRuns.count == 1 }
        let inlay: EditorInlayLayout = try #require(Self.stored("inlayLayout", in: coordinator))
        let originalID = try #require(view.displayAdapter?.document.map.hintRuns.first?.hint.id)
        #expect(inlay.activate(.edits, id: originalID))
        try await Self.eventually("inlay preview") { window.attachedSheet != nil }
        let preview = try #require(window.attachedSheet?.contentViewController as? NSHostingController<WorkspaceEditPreview>).rootView
        #expect(preview.model.plan.steps.count == 1)
        #expect(preview.model.plan.steps.first?.document.uri == file.lspURI)
        #expect(buffer.storage.string == "let value = 1\n")
        #expect(try String(contentsOf: file, encoding: .utf8) == "let value = 1\n")
        #expect(await preview.model.apply())
        preview.close()
        try await Self.eventually("applied inlay with undo") { buffer.storage.string == "let value: Int = 1\n" && buffer.undoManager.canUndo && window.attachedSheet == nil }
        #expect(try String(contentsOf: file, encoding: .utf8) == "let value = 1\n")
        #expect(!inlay.activate(.edits, id: originalID))
        buffer.undoManager.undo()
        try await Self.eventually("inlay undo") { buffer.storage.string == "let value = 1\n" && buffer.undoManager.canRedo }
        #expect(!buffer.undoManager.canUndo)
        buffer.undoManager.redo()
        try await Self.eventually("inlay redo") { buffer.storage.string == "let value: Int = 1\n" && buffer.undoManager.canUndo }
        buffer.undoManager.undo()
        try await Self.eventually("fresh inlay after undo") { buffer.storage.string == "let value = 1\n" && view.displayAdapter?.document.map.hintRuns.count == 1 }
        let freshID = try #require(view.displayAdapter?.document.map.hintRuns.first?.hint.id)
        #expect(inlay.activate(.edits, id: freshID))
        try await Self.eventually("second preview") { window.attachedSheet != nil }
        let stale = try #require(window.attachedSheet?.contentViewController as? NSHostingController<WorkspaceEditPreview>).rootView
        view.setSourceSelectedRange(NSRange(location: buffer.storage.length, length: 0))
        view.insertText("// user edit\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!inlay.activate(.edits, id: freshID))
        #expect(await stale.model.apply() == false)
        stale.close()
        #expect(buffer.storage.string == "let value = 1\n// user edit\n")
        #expect(try String(contentsOf: file, encoding: .utf8) == "let value = 1\n")
    }

    @Test func zeroWidthEOFWarningKeepsItsMarkerTooltipWithHints() async throws {
        let f = try await Fixture("a\u{200B}")
        defer { f.remove() }
        let layout = try #require(f.view.layoutManager as? CodeEditorLayoutManager)
        var config = AppConfig.defaults
        config.code.showWarningCharacters = true
        config.code.warningCharacters = [WarningCharacter(scalarValue: 0x200B, note: "Zero width")]
        layout.update(configuration: CodeEditorTextRenderingConfiguration(code: config.code), theme: try ThemeStore().current)
        let caret = try #require(f.view.sourceInsertionRect(inViewAt: 2))
        let point = NSPoint(x: caret.minX + 2, y: caret.midY)
        #expect(layout.warningToolTip(at: point, in: f.view)?.contains("Zero width") == true)
    }

    @Test func diagnosticBatchRepaintsWithoutRebuildingProjectionAndPreservesSourceState() async throws {
        final class Counts: @unchecked Sendable {
            var sourceNotifications = 0
            var projectionRebuilds = 0
        }

        let source = String(repeating: "x ", count: 200)
        let f = try await Fixture(source)
        defer { f.remove() }
        f.view.setSourceSelectedRange(NSRange(location: 120, length: 17))
        let expectedSelection = f.view.sourceSelectedRange
        let diagnostics = try (0..<200).map { index in
            try JSONDecoder().decode(LSPDiagnostic.self, from: Data("""
            {"range":{"start":{"line":0,"character":\(index * 2)},"end":{"line":0,"character":\(index * 2 + 1)}},"severity":1,"message":"Problem \(index)"}
            """.utf8))
        }
        let counts = Counts()
        let center = NotificationCenter.default
        let sourceToken = center.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: f.buffer.storage, queue: .main) { _ in
            counts.sourceNotifications += 1
        }
        let projectionToken = center.addObserver(forName: .editorDisplayProjectionDidChange, object: f.view, queue: .main) { _ in
            counts.projectionRebuilds += 1
        }
        defer {
            center.removeObserver(sourceToken)
            center.removeObserver(projectionToken)
        }

        DiagnosticsFeature().apply(diagnostics, to: f.buffer.storage, theme: try ThemeStore().current)

        #expect(counts.sourceNotifications == 1)
        #expect(counts.projectionRebuilds == 0)
        #expect(f.buffer.storage.string == source)
        #expect(f.view.sourceString == source)
        #expect(f.view.sourceSelectedRange == expectedSelection)
        let adapter = try #require(f.view.displayAdapter)
        for offset in [0, 198, 398] {
            let range = try #require(adapter.displayRange(forSource: NSRange(location: offset, length: 1)))
            #expect(adapter.document.storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int != nil)
        }
    }

    @Test func sourceAttributesAndSemanticColorsExcludeHintsAfterRebuild() async throws {
        let f = try await Fixture("alpha")
        defer { f.remove() }
        let font = NSFont.monospacedSystemFont(ofSize: 19, weight: .regular)
        f.buffer.storage.addAttributes([.font: font, .foregroundColor: NSColor.red, .underlineStyle: 1], range: NSRange(location: 0, length: 5))
        let layout = try #require(f.view.layoutManager)
        let theme = EditorTheme(theme: try ThemeStore().current)
        let revision = f.buffer.editGeneration
        let context = EditorRequestContext(document: .init(host: nil, worktreeID: "w", uri: "file:///file.swift"), version: 1, serverGeneration: UUID(), range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 5)))
        let semantic = EditorSemanticLayer(layoutManager: layout, theme: theme, textView: f.view, isCurrent: { _ in f.buffer.editGeneration == revision })
        semantic.replace([.init(range: NSRange(location: 0, length: 5), capture: .function)], context: context)
        try f.hints(offset: 3)
        #expect(f.view.textStorage?.attribute(.attachment, at: 3, effectiveRange: nil) != nil)
        #expect(f.view.textStorage?.attribute(.underlineStyle, at: 3, effectiveRange: nil) == nil)
        #expect(f.view.textStorage?.attribute(.underlineStyle, at: 5, effectiveRange: nil) as? Int == 1)
        #expect(f.view.textStorage?.attribute(.font, at: 5, effectiveRange: nil) as? NSFont == font)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 3, effectiveRange: nil) == nil)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 5, effectiveRange: nil) != nil)
        semantic.replace([.init(range: NSRange(location: 0, length: 6), capture: .type)], context: context)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 3, effectiveRange: nil) == nil)
    }

    // Exercises the deprecated AppKit AX entry points on purpose.
    @available(macOS, deprecated: 10.10)
    @Test func parameterizedAccessibilityReturnsSourceRangesAndText() async throws {
        let f = try await Fixture("ab\n🙂z")
        defer { f.remove() }
        #expect(f.view.accessibilityAttributeValue(.stringForRange, forParameter: NSValue(range: NSRange(location: 3, length: 2))) as? String == "🙂")
        #expect((f.view.accessibilityAttributeValue(.rangeForLine, forParameter: NSNumber(value: 1)) as? NSValue)?.rangeValue == NSRange(location: 3, length: 3))
        #expect(f.view.accessibilityAttributeValue(.lineForIndex, forParameter: NSNumber(value: 3)) as? Int == 1)
        f.view.accessibilitySetValue(NSValue(range: NSRange(location: 3, length: 2)), forAttribute: .selectedTextRange)
        #expect(f.view.sourceSelectedRange == NSRange(location: 3, length: 2))
        #expect(f.view.accessibilityAttributeValue(.selectedText) as? String == "🙂")
        f.view.accessibilitySetValue("x", forAttribute: .selectedText)
        #expect(f.view.sourceString == "ab\nxz")
        f.buffer.undoManager.undo()
        #expect(f.view.sourceString == "ab\n🙂z")
    }

    @Test(arguments: ["cancel", "accept", "stale"])
    func coordinatorCompletionPayloadAndImportUndoSurviveHintRefresh(acceptFollowup: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.swift")
        try Data("\npr".utf8).write(to: file)
        let transport = FakeTransport()
        var completionRequest: LSPJSONValue?
        var definitionRequest: LSPJSONValue?
        var signatureRequest: LSPJSONValue?
        var renameRequest: LSPJSONValue?
        var renameEditRequest: LSPJSONValue?
        var actionsRequest: LSPJSONValue?
        transport.onSend = { sent in
            guard let request = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = request["id"] else { return }
            let result: LSPJSONValue
            switch request["method"]?.stringValue {
            case "initialize":
                result = try! LSPJSONValue.decode(from: Data(#"{"capabilities":{"completionProvider":{},"definitionProvider":true,"signatureHelpProvider":{"triggerCharacters":["("]},"renameProvider":{"prepareProvider":true},"codeActionProvider":true}}"#.utf8))
            case "textDocument/completion": completionRequest = request
                return
            case "workspace/executeCommand":
                transport.deliverFrame("""
                {"id":"completion-followup","method":"workspace/applyEdit","params":{"edit":{"changes":{"\(file.lspURI)":[{"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":1}},"newText":"P"}]}}}}
                """)
                result = .null
            case "textDocument/definition": definitionRequest = request
                result = .array([])
            case "textDocument/signatureHelp": signatureRequest = request
                result = .null
            case "textDocument/prepareRename": renameRequest = request
                result = try! LSPJSONValue.decode(from: Data(#"{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":2}},"placeholder":"renamed"}"#.utf8))
            case "textDocument/rename": renameEditRequest = request
                result = .object(["changes": .object([file.lspURI: .array([Self.edit(line: 1, start: 0, end: 2, text: "renamed")])])])
            case "textDocument/codeAction": actionsRequest = request
                result = .array([.object(["title": .string("Replace source symbol"), "edit": .object(["changes": .object([file.lspURI: .array([Self.edit(line: 1, start: 0, end: 2, text: "fixed")])])])])])
            default: result = .null
            }
            let response: LSPJSONValue = .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
            transport.deliverFrame(String(decoding: try! response.encodedData(), as: UTF8.self))
        }
        let client = LSPClient(transport: transport, language: "swift", rootURI: root.lspURI)
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: [LanguageServerConfig(language: "swift", extensions: ["swift"], command: "/usr/bin/true", args: [], env: [:], rootMarkers: [], enabled: true)]), makeClient: { _, _, _, _, _ in client })
        let tabs = TabsManager(bufferStore: EditorBufferStore(rootOverride: root.appendingPathComponent("buffers")), lsp: manager, tabsDirectory: root.appendingPathComponent("tabs"), workspaceEditJournal: WorkspaceEditJournal(root: root.appendingPathComponent("journal")))
        let app = AppState(tabsManager: tabs, lspManager: manager)
        let buffer = tabs.buffer(worktreeId: "projection", tabId: "tab", worktreeRoot: root, relativePath: "file.swift")
        await buffer.awaitLoadForTesting()
        await buffer.awaitWorkspaceEditLifecycle()
        buffer.stopWatching()
        let layout = CodeEditorLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 800, height: 600))
        layout.addTextContainer(container)
        let view = CodeTextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        let window = NSWindow(contentRect: view.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        let coordinator = CodeEditorCoordinator(appState: app)
        coordinator.attach(textView: view, buffer: buffer, layoutManager: layout, worktreeId: "projection", worktreeRoot: root, tabId: "tab", revealLine: nil, revealCharacter: nil, theme: try ThemeStore().current)
        defer { coordinator.detach()
            window.orderOut(nil)
            window.contentView = nil
            buffer.close(persistDirtySnapshot: false)
            transport.finish()
        }
        for _ in 0..<200 where manager.documentStatus(forFile: file, worktreeRoot: root) != .ready { try await Task.sleep(for: .milliseconds(10)) }
        view.setSourceSelectedRange(NSRange(location: 3, length: 0))
        try view.displayAdapter?.updateHints([.init(id: "hint", sourceOffset: 2, label: "type:", size: CGSize(width: 50, height: 16))], revision: buffer.editGeneration)
        view.complete(nil)
        for _ in 0..<200 where completionRequest == nil { try await Task.sleep(for: .milliseconds(10)) }
        let request = try #require(completionRequest)
        #expect(request["params"]?["position"]?["line"] == .number("1"))
        #expect(request["params"]?["position"]?["character"] == .number("2"))
        try view.displayAdapter?.updateHints([.init(id: "hint", sourceOffset: 1, label: "changed", size: CGSize(width: 90, height: 16))], revision: buffer.editGeneration)
        let item = try LSPJSONValue.decode(from: Data(#"{"label":"print","additionalTextEdits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"import Foo\n"}],"command":{"title":"Complete import","command":"completion.followup"}}"#.utf8))
        let response: LSPJSONValue = .object(["jsonrpc": .string("2.0"), "id": try #require(request["id"]), "result": .array([item])])
        transport.deliverFrame(String(decoding: try response.encodedData(), as: UTF8.self))
        try await Self.eventually("completion popup") {
            window.childWindows?.contains(where: { ($0.contentViewController as? NSHostingController<CompletionPopup>)?.rootView.rows.contains(where: { $0.label == "print" }) == true }) == true
        }
        view.insertTab(nil)
        for _ in 0..<200 where buffer.storage.string == "\npr" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(buffer.storage.string == "import Foo\n\nprint")
        for _ in 0..<200 where view.sourceSelectedRange != NSRange(location: 17, length: 0) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.sourceSelectedRange == NSRange(location: 17, length: 0))
        try await Self.eventually("completion command edit preview") { window.attachedSheet != nil }
        let followup = try #require(window.attachedSheet?.contentViewController as? NSHostingController<WorkspaceEditPreview>).rootView
        if acceptFollowup == "stale" {
            view.insertText(" user", replacementRange: NSRange(location: buffer.storage.length, length: 0))
            #expect(await followup.model.apply() == false)
            followup.close()
            #expect(buffer.storage.string == "import Foo\n\nprint user")
            buffer.undoManager.undo()
            #expect(buffer.storage.string == "import Foo\n\nprint")
        } else if acceptFollowup == "accept" {
            #expect(await followup.model.apply())
            followup.close()
            #expect(buffer.storage.string == "import Foo\n\nPrint")
            buffer.undoManager.undo()
            try await Self.eventually("completion follow-up undo") { buffer.storage.string == "import Foo\n\nprint" && !buffer.undoManager.workspaceActionInFlight }
            #expect(!buffer.undoManager.workspaceActionInFlight, "Completion undo must finish before the next native action")
        } else { followup.cancel?() }
        try await Self.eventually("completion sheet dismissal") { window.attachedSheet == nil }
        #expect(buffer.storage.string == "import Foo\n\nprint")
        buffer.undoManager.undo()
        for _ in 0..<200 where buffer.storage.string != "\npr" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(buffer.storage.string == "\npr")
        #expect(!buffer.undoManager.canUndo)
        view.setSourceSelectedRange(NSRange(location: 3, length: 0))
        try view.displayAdapter?.updateHints([.init(id: "hint", sourceOffset: 2, label: "type:", size: CGSize(width: 50, height: 16))], revision: buffer.editGeneration)
        view.triggerCommandClick(atUTF16Offset: 2)
        view.signatureHelpManualTriggerHandler?()
        for _ in 0..<200 where definitionRequest == nil || signatureRequest == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(definitionRequest?["params"]?["position"]?["character"] == .number("1"))
        #expect(signatureRequest?["params"]?["position"]?["character"] == .number("2"))
        view.setSourceSelectedRange(NSRange(location: 1, length: 2))
        view.renameSymbol(nil)
        let rename: RenameFeature = try #require(Self.stored("renameFeature", in: coordinator))
        try await Self.eventually("rename picker") { Self.popover(in: rename)?.isShown == true }
        let renamePopover = try #require(Self.popover(in: rename))
        let renameView = try #require(renamePopover.contentViewController as? NSHostingController<RenameNameView>).rootView
        #expect(renameView.model.name == "renamed")
        renameView.submit()
        try await Self.eventually("rename applied with undo registered") { buffer.storage.string == "\nrenamed" && buffer.undoManager.canUndo }
        #expect(renameRequest?["params"]?["position"]?["character"] == .number("0"))
        #expect(renameEditRequest?["params"]?["newName"] == .string("renamed"))
        #expect(renameEditRequest?["params"]?["position"]?["line"] == .number("1"))
        #expect(renameEditRequest?["params"]?["position"]?["character"] == .number("0"))
        buffer.undoManager.undo()
        try await Self.eventually("rename undo") { buffer.storage.string == "\npr" && !buffer.undoManager.workspaceActionInFlight }
        #expect(!buffer.undoManager.workspaceActionInFlight, "Rename undo must finish before code actions can run")
        #expect(!buffer.undoManager.canUndo)
        view.setSourceSelectedRange(NSRange(location: 1, length: 2))
        try view.displayAdapter?.updateHints([.init(id: "action", sourceOffset: 1, label: "action", size: CGSize(width: 200, height: 30))], revision: buffer.editGeneration)
        view.showCodeActions(nil)
        let actions: CodeActionsFeature = try #require(Self.stored("codeActionsFeature", in: coordinator))
        try await Self.eventually("code action picker") { Self.popover(in: actions)?.isShown == true }
        let actionsPopover = try #require(Self.popover(in: actions))
        let picker = try #require(actionsPopover.contentViewController as? NSHostingController<CodeActionPicker>).rootView
        try await Self.eventually("code actions loaded") { !picker.model.isLoading }
        let action = try #require(picker.model.filtered.first?.action)
        #expect(action.title == "Replace source symbol")
        picker.select(action)
        try await Self.eventually("code action edit preview") { window.attachedSheet != nil }
        let preview = try #require(window.attachedSheet?.contentViewController as? NSHostingController<WorkspaceEditPreview>).rootView
        #expect(preview.model.plan.steps.count == 1)
        #expect(preview.model.plan.steps.first?.document.uri == file.lspURI)
        #expect(buffer.storage.string == "\npr")
        #expect(await preview.model.apply())
        preview.close()
        try await Self.eventually("code action applied and sheet dismissed") { buffer.storage.string == "\nfixed" && window.attachedSheet == nil }
        #expect(actionsRequest?["params"]?["range"]?["start"]?["character"] == .number("0"))
        #expect(actionsRequest?["params"]?["range"]?["end"]?["character"] == .number("2"))
        buffer.undoManager.undo()
        try await Self.eventually("code action undo") { buffer.storage.string == "\npr" && !buffer.undoManager.workspaceActionInFlight }
        #expect(!buffer.undoManager.workspaceActionInFlight, "Code action undo must finish before navigation can run")
        #expect(!buffer.undoManager.canUndo)

        let diagnostic = try JSONDecoder().decode(LSPDiagnostic.self, from: Data("""
        {"range":{"start":{"line":1,"character":1},"end":{"line":1,"character":2}},"severity":1,"message":"Problem","relatedInformation":[{"location":{"uri":"\(file.lspURI)","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":1}}},"message":"Related source"}]}
        """.utf8))
        coordinator.diagnosticsFeature.apply([diagnostic], to: buffer.storage, theme: try ThemeStore().current)
        view.setSourceSelectedRange(NSRange(location: 0, length: 0))
        try view.displayAdapter?.updateHints([.init(id: "diagnostic", sourceOffset: 1, label: "diagnostic", size: CGSize(width: 90, height: 16))], revision: buffer.editGeneration)
        view.nextProblem(nil)
        #expect(view.sourceSelectedRange == NSRange(location: 2, length: 1))
        #expect(view.selectedRange() == NSRange(location: 3, length: 1))
        try await Self.eventually("diagnostic details after code action undo") { Self.documentationView(in: window) != nil }
        let documentation = try #require(Self.documentationView(in: window))
        let link = URL(string: "alas-diagnostic://related/0")!
        #expect(documentation.delegate?.textView?(documentation, clickedOnLink: link, at: 0) == true)
        let history = tabs.navigationStore(forWorktreeId: "projection")
        #expect(history.goBack()?.position == LSPPosition(line: 1, character: 1))
        #expect(history.goForward()?.position == LSPPosition(line: 1, character: 0))
        if case .editor(let target) = tabs.activeTab(forWorktree: "projection") {
            #expect(target.revealLine == 1)
            #expect(target.revealCharacter == 0)
        } else { Issue.record("Diagnostic link did not activate an editor tab") }
        #expect(buffer.storage.string == "\npr")
        #expect(!buffer.undoManager.canUndo)
    }

    @Test(arguments: ["e\u{301} office", "👩‍👩‍👧‍👦 office", "abc אבג office", "office\n"]) func unicodeGeometryAndAccessibilityKeepSourceBoundaries(_ source: String) async throws {
        let f = try await Fixture(source)
        defer { f.remove() }
        let length = source.utf16.count
        try f.view.displayAdapter?.updateHints([.init(id: "start", sourceOffset: 0, label: "a", size: CGSize(width: 20, height: 16)), .init(id: "end", sourceOffset: length, label: "b", size: CGSize(width: 20, height: 16))], revision: f.buffer.editGeneration)
        let window = NSWindow(contentRect: f.view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = f.view
        f.view.setSourceSelectedRange(NSRange(location: 0, length: length))
        #expect(f.view.accessibilityString(for: NSRange(location: 0, length: length)) == source)
        #expect(f.view.accessibilityNumberOfCharacters() == length)
        #expect(!f.view.accessibilityFrame(for: NSRange(location: 0, length: length)).isEmpty)
        #expect(!f.view.accessibilityFrame(for: NSRange(location: length, length: 0)).isEmpty)
        #expect(f.view.accessibilityLine(for: length) == (source.hasSuffix("\n") ? 1 : 0))
        #expect(f.view.accessibilityChildren()?.count == 2)
        if source.hasPrefix("👩") {
            do { try f.hints(offset: 1)
                Issue.record("Accepted an anchor inside a surrogate pair")
            } catch { }
            #expect(f.view.sourceString == source)
        }
        window.contentView = nil
    }

    @Test func minimapUsesSourceRunsAndSourceLineNavigation() async throws {
        let f = try await Fixture("alpha\nbeta\ngamma\n" + String(repeating: "last\n", count: 30))
        defer { f.remove() }
        let scroll = CodeEditorScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 90))
        scroll.documentView = f.view
        let theme = try ThemeStore().current
        scroll.configureMinimap(shown: true, theme: theme)
        try await Task.sleep(for: .milliseconds(150))
        let plain = MinimapDrawing.editorText(f.buffer.storage)
        // A wide attachment wraps a source line without becoming a minimap mark.
        try f.view.displayAdapter?.updateHints([.init(id: "wide", sourceOffset: 1, label: "very wide", size: CGSize(width: 1800, height: 40))], revision: f.buffer.editGeneration)
        try await Task.sleep(for: .milliseconds(150))
        let projected = try #require(Mirror(reflecting: scroll.minimap).children.first(where: { $0.label == "drawing" })?.value as? MinimapDrawing)
        #expect(projected.marks.count == plain.marks.count)
        #expect(projected.height == plain.height)
    }

    @Test func hoverHitRejectsHintButPreservesSourceObjectReplacementCharacter() async throws {
        let f = try await Fixture("a\u{FFFC}b")
        defer { f.remove() }
        let layout = try #require(f.view.layoutManager)
        let container = try #require(f.view.textContainer)
        layout.ensureLayout(for: container)
        func point(_ offset: Int) -> NSPoint {
            let glyph = layout.glyphIndexForCharacter(at: offset)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return NSPoint(x: rect.midX + f.view.textContainerOrigin.x, y: rect.midY + f.view.textContainerOrigin.y)
        }
        #expect(f.view.utf16Offset(at: point(1)) == nil)
        #expect(f.view.utf16Offset(at: point(3)) == 2)
        #expect(f.view.lspPosition(at: point(3)) == LSPPosition(line: 0, character: 2))
    }

    @Test func findSearchesSourceAcrossHintsAndReplacementUndoesOnce() async throws {
        let f = try await Fixture("alpha alpha")
        defer { f.remove() }
        let find = EditorFindController()
        find.textView = f.view
        find.findString = "alpha"
        find.replacementString = "beta"
        find.refreshMatches(selecting: .first)
        #expect(find.matches == [NSRange(location: 0, length: 5), NSRange(location: 6, length: 5)])
        #expect(f.view.sourceSelectedRange == NSRange(location: 0, length: 5))
        #expect(find.replaceAll() == 2)
        #expect(f.view.sourceString == "beta beta")
        f.buffer.undoManager.undo()
        #expect(f.view.sourceString == "alpha alpha")
        #expect(!f.buffer.undoManager.canUndo)
    }

    @Test func findBackgroundExcludesHintAndSurvivesRefresh() async throws {
        let f = try await Fixture("alpha")
        defer { f.remove() }
        let renderer = EditorFindHighlightRenderer()
        renderer.attach(textView: f.view)
        renderer.render(matches: [NSRange(location: 0, length: 5)], activeIndex: 0, inactiveColor: .yellow, activeColor: .orange)
        #expect(f.view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 1, effectiveRange: nil) == nil)
        #expect(f.view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 5, effectiveRange: nil) as? NSColor == .orange)
        try f.hints(offset: 3)
        #expect(f.view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 3, effectiveRange: nil) == nil)
        #expect(f.view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 5, effectiveRange: nil) as? NSColor == .orange)
    }

    @Test func accessibilityUsesSourceValueAndSelection() async throws {
        let f = try await Fixture("a\u{FFFC}🙂b")
        defer { f.remove() }
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 2, length: 2))])
        #expect(f.view.accessibilityValue() == "a\u{FFFC}🙂b")
        #expect(f.view.accessibilitySelectedTextRange() == NSRange(location: 2, length: 2))
        #expect(f.view.accessibilitySelectedText() == "🙂")
        #expect(f.view.accessibilityString(for: NSRange(location: 1, length: 3)) == "\u{FFFC}🙂")
        f.view.setAccessibilitySelectedTextRange(NSRange(location: 4, length: 1))
        #expect(f.view.sourceSelectedRange == NSRange(location: 4, length: 1))
    }

    // Exercises the deprecated AppKit AX entry points on purpose.
    @available(macOS, deprecated: 10.10)
    @Test(arguments: [
        ("e\u{301} office", NSRange(location: 0, length: 2)),
        ("👩‍👩‍👧‍👦 office", NSRange(location: 0, length: 11)),
        ("abc אבג office", NSRange(location: 4, length: 3)),
        ("office\n", NSRange(location: 0, length: 6))
    ]) func unicodeRectsOccupyTheMappedGlyphs(_ source: String, _ range: NSRange) async throws {
        let f = try await Fixture(source)
        defer { f.remove() }
        Self.configureLayout(f.view, buffer: f.buffer, width: 160, fontSize: 20)
        f.buffer.storage.addAttribute(.font, value: try #require(NSFont(name: source == "office\n" ? "Hoefler Text" : "Times New Roman", size: 20)), range: NSRange(location: 0, length: source.utf16.count))
        let window = NSWindow(contentRect: f.view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = f.view
        defer { window.contentView = nil }
        try f.view.displayAdapter?.updateHints([
            .init(id: "leading", sourceOffset: 0, label: "leading", size: CGSize(width: 150, height: 30)),
            .init(id: "eof", sourceOffset: source.utf16.count, label: "eof", size: CGSize(width: 110, height: 22))
        ], revision: f.buffer.editGeneration)
        let layout = try #require(f.view.layoutManager)
        let container = try #require(f.view.textContainer)
        layout.ensureLayout(for: container)
        // The one leading attachment adds exactly one native UTF-16 unit.
        let native = NSRange(location: range.location + 1, length: range.length)
        if source == "office\n" {
            // TextKit retains null slots for the characters absorbed by ffi.
            let glyphs = layout.glyphRange(forCharacterRange: native, actualCharacterRange: nil)
            let visible = (glyphs.location..<NSMaxRange(glyphs)).filter { !layout.propertyForGlyph(at: $0).contains(.null) }
            #expect(visible.count == 4)
        }
        let expected = Self.nativeRects(native, in: f.view)
        #expect(f.view.sourceRects(inViewFor: range) == expected)
        let expectedFrame = window.convertToScreen(f.view.convert(expected.dropFirst().reduce(try #require(expected.first)) { $0.union($1) }, to: nil))
        #expect(f.view.accessibilityFrame(for: range) == expectedFrame)
        #expect((f.view.accessibilityAttributeValue(.boundsForRange, forParameter: NSValue(range: range)) as? NSValue)?.rectValue == expectedFrame)
        let hint = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil), in: container)
        #expect(expected.allSatisfy { !$0.intersects(hint) })
        let glyph = layout.glyphIndexForCharacter(at: native.location)
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        var point = NSPoint(x: glyphRect.midX, y: glyphRect.midY)
        if source == "abc אבג office" {
            // Times' conservative glyph box includes neighboring characters.
            // Place the hit inside this Hebrew glyph's actual ink instead.
            let font = try #require(f.view.textStorage?.attribute(.font, at: native.location, effectiveRange: nil) as? NSFont)
            let ink = font.boundingRect(forGlyph: layout.glyph(at: glyph))
            let origin = layout.location(forGlyphAt: glyph)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            point = NSPoint(x: line.minX + origin.x + ink.midX, y: line.minY + origin.y - ink.midY)
            #expect(layout.glyphIndex(for: point, in: container) == glyph)
        }
        let sourceHit = try #require(f.view.utf16Offset(at: point))
        #expect(NSLocationInRange(sourceHit, range))
        let screenPoint = window.convertPoint(toScreen: f.view.convert(point, to: nil))
        let axHit = f.view.accessibilityRange(for: screenPoint)
        #expect(NSLocationInRange(axHit.location, range))
        #expect(f.view.accessibilityString(for: axHit) == (source as NSString).substring(with: axHit))
    }

    @Test func accessibilityHintActionsNavigateAndRejectStaleOwners() async throws {
        let f = try await Fixture("alpha\nbeta")
        let other = try await Fixture("alpha\nbeta")
        defer { f.remove()
        other.remove() }
        try f.hints(offset: 6)
        let child = try #require(f.view.accessibilityChildren()?.first as? NSAccessibilityElement)
        let action = try #require(child.accessibilityCustomActions()?.first)
        f.view.setSourceSelectedRange(NSRange(location: 0, length: 0))
        #expect(action.handler?() == true)
        #expect(f.view.sourceSelectedRange == NSRange(location: 6, length: 0))
        #expect(f.view.sourceString == "alpha\nbeta")
        #expect(!f.buffer.undoManager.canUndo)
        try f.hints(offset: 1)
        f.view.setSourceSelectedRange(NSRange(location: 0, length: 0))
        #expect(action.handler?() == false)
        #expect(f.view.sourceSelectedRange.location == 0)
        try f.hints(offset: 6)
        let beforeEdit = try #require((f.view.accessibilityChildren()?.first as? NSAccessibilityElement)?.accessibilityCustomActions()?.first)
        #expect(f.view.replaceSource(range: NSRange(location: 0, length: 0), with: "x"))
        #expect(beforeEdit.handler?() == false)
        f.buffer.undoManager.undo()
        try f.hints(offset: 6)
        let beforeRebind = try #require((f.view.accessibilityChildren()?.first as? NSAccessibilityElement)?.accessibilityCustomActions()?.first)
        try f.view.bindDisplay(to: other.buffer)
        try f.view.displayAdapter?.updateHints([.init(id: "hint", sourceOffset: 6, label: "type:", size: CGSize(width: 50, height: 16))], revision: other.buffer.editGeneration)
        f.view.setSourceSelectedRange(NSRange(location: 0, length: 0))
        #expect(beforeRebind.handler?() == false)
        #expect(f.view.sourceSelectedRange.location == 0)
        #expect(other.buffer.storage.string == "alpha\nbeta")
        #expect(!other.buffer.undoManager.canUndo)
    }

    @Test func minimapNavigationAndViewportFollowWrappedSourceLines() async throws {
        let f = try await Fixture(String(repeating: "line\n", count: 25))
        defer { f.remove() }
        Self.configureLayout(f.view, buffer: f.buffer, width: 140, fontSize: 20)
        try f.view.displayAdapter?.updateHints([
            .init(id: "leading", sourceOffset: 0, label: "wide", size: CGSize(width: 300, height: 50)),
            .init(id: "eof", sourceOffset: 125, label: "end", size: CGSize(width: 120, height: 24))
        ], revision: f.buffer.editGeneration)
        let layout = try #require(f.view.layoutManager)
        let container = try #require(f.view.textContainer)
        layout.ensureLayout(for: container)
        func y(_ native: Int) -> CGFloat { layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: native), effectiveRange: nil).minY }
        let lineHeight = y(11) - y(6)
        let scroll = CodeEditorScrollView(frame: NSRect(x: 0, y: 0, width: 140, height: lineHeight * 4))
        f.view.setFrameSize(NSSize(width: 140, height: layout.usedRect(for: container).height))
        scroll.documentView = f.view
        scroll.configureMinimap(shown: true, theme: try ThemeStore().current)
        #expect(f.view.sourceLineY(0) == y(0))
        #expect(f.view.sourceLineY(1) == y(6))
        #expect(f.view.sourceLineY(25) == y(126))
        #expect(y(1) > y(0))
        let maxY = f.view.frame.height - scroll.contentView.bounds.height
        // Source line 22 begins at native 111 after the leading attachment.
        let maxPosition = 22 + Double((maxY - y(111)) / lineHeight)
        scroll.minimap.onNavigate?(10 / maxPosition)
        #expect(abs(scroll.contentView.bounds.minY - y(51)) < 0.01)
        #expect(abs(scroll.minimap.value - 10 / maxPosition) < 0.001)
        #expect(abs(scroll.minimap.proportion - 4.0 / 26.0) < 0.001)
        scroll.minimap.onNavigate?(1)
        #expect(abs(scroll.contentView.bounds.minY - maxY) < 0.01)
        scroll.minimap.onNavigate?(0)
        #expect(abs(scroll.contentView.bounds.minY) < 0.01)
        let oldLineOne = y(6)
        f.buffer.storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 30, weight: .regular), range: NSRange(location: 0, length: 125))
        layout.ensureLayout(for: container)
        #expect(f.view.sourceLineY(1) == y(6))
        #expect(y(6) > oldLineOne)
    }

    @Test func projectionRefreshKeepsTheLeadingFragmentScrollAnchor() async throws {
        let f = try await Fixture(String(repeating: "line\n", count: 40))
        defer { f.remove() }
        Self.configureLayout(f.view, buffer: f.buffer, width: 140, fontSize: 20)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 140, height: 80))
        f.view.setFrameSize(NSSize(width: 140, height: 2000))
        scroll.documentView = f.view
        try f.view.displayAdapter?.updateHints([.init(id: "leading", sourceOffset: 50, label: "wide", size: CGSize(width: 300, height: 50))], revision: f.buffer.editGeneration)
        let y = try #require(f.view.sourceLineY(10))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y + 2))
        try f.view.displayAdapter?.updateHints([.init(id: "leading", sourceOffset: 50, label: "narrow", size: CGSize(width: 20, height: 16))], revision: f.buffer.editGeneration)
        #expect(abs(scroll.contentView.bounds.minY - (try #require(f.view.sourceLineY(10)) + 2)) < 0.01)
    }

    @Test func tabSwitchRestoresSourceSelectionAndScrollWithoutOldHints() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(String(repeating: "line\n", count: 40).utf8).write(to: root.appendingPathComponent("first.txt"))
        try Data("other\n".utf8).write(to: root.appendingPathComponent("second.txt"))
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: []))
        let tabs = TabsManager(bufferStore: EditorBufferStore(rootOverride: root.appendingPathComponent("buffers")), lsp: manager, tabsDirectory: root.appendingPathComponent("tabs"), workspaceEditJournal: WorkspaceEditJournal(root: root.appendingPathComponent("journal")))
        let app = AppState(tabsManager: tabs, lspManager: manager)
        let first = tabs.buffer(worktreeId: "tabs", tabId: "first", worktreeRoot: root, relativePath: "first.txt")
        let second = tabs.buffer(worktreeId: "tabs", tabId: "second", worktreeRoot: root, relativePath: "second.txt")
        for buffer in [first, second] { await buffer.awaitLoadForTesting()
        await buffer.awaitWorkspaceEditLifecycle()
        buffer.stopWatching() }
        let layout = CodeEditorLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 140, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 140, height: 2000), textContainer: container)
        let scroll = CodeEditorScrollView(frame: NSRect(x: 0, y: 0, width: 140, height: 80))
        scroll.documentView = view
        let coordinator = CodeEditorCoordinator(appState: app)
        let theme = try ThemeStore().current
        coordinator.attach(textView: view, buffer: first, layoutManager: layout, worktreeId: "tabs", worktreeRoot: root, tabId: "first", revealLine: nil, revealCharacter: nil, theme: theme)
        defer { coordinator.detach()
        first.close(persistDirtySnapshot: false)
        second.close(persistDirtySnapshot: false) }
        Self.configureLayout(view, buffer: first, width: 140, fontSize: 20)
        try view.displayAdapter?.updateHints([.init(id: "leading", sourceOffset: 0, label: "wide", size: CGSize(width: 300, height: 50)), .init(id: "end", sourceOffset: 200, label: "end", size: CGSize(width: 160, height: 40))], revision: first.editGeneration)
        view.setSourceSelectedRange(NSRange(location: 52, length: 2))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: try #require(view.sourceLineY(10)) + 2))
        coordinator.updateIfNeeded(worktreeId: "tabs", worktreeRoot: root, relativePath: "second.txt", tabId: "second", revealLine: nil, revealCharacter: nil, theme: theme)
        #expect(view.sourceString == "other\n")
        #expect(view.sourceSelectedRange == NSRange(location: 0, length: 0))
        #expect(scroll.contentView.bounds.minY == 0)
        coordinator.updateIfNeeded(worktreeId: "tabs", worktreeRoot: root, relativePath: "first.txt", tabId: "first", revealLine: nil, revealCharacter: nil, theme: theme)
        #expect(view.sourceSelectedRange == NSRange(location: 52, length: 2))
        #expect(view.displayAdapter?.document.map.hintRuns.isEmpty == true)
        #expect(abs(scroll.contentView.bounds.minY - (try #require(view.sourceLineY(10)) + 2)) < 0.01)
        try view.displayAdapter?.updateHints([.init(id: "leading", sourceOffset: 0, label: "narrow", size: CGSize(width: 20, height: 16))], revision: first.editGeneration)
        #expect(view.sourceSelectedRange == NSRange(location: 52, length: 2))
        #expect(abs(scroll.contentView.bounds.minY - (try #require(view.sourceLineY(10)) + 2)) < 0.01)
    }

    @Test func rulerNumbersFirstFragmentsAndEOFFromSourceLines() async throws {
        let f = try await Fixture("alpha beta gamma delta\nz\n")
        defer { f.remove() }
        Self.configureLayout(f.view, buffer: f.buffer, width: 90, fontSize: 20)
        try f.view.displayAdapter?.updateHints([.init(id: "leading", sourceOffset: 0, label: "wide", size: CGSize(width: 120, height: 36)), .init(id: "end", sourceOffset: 25, label: "eof", size: CGSize(width: 80, height: 30))], revision: f.buffer.editGeneration)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 134, height: 400))
        scroll.documentView = f.view
        let theme = try ThemeStore().current
        let ruler = CodeEditorLineNumberRulerView(scrollView: scroll, textView: f.view, theme: theme)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.tile()
        let layout = try #require(f.view.layoutManager)
        let container = try #require(f.view.textContainer)
        layout.ensureLayout(for: container)
        func raster(_ draw: () -> Void) throws -> Data {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 176, bitsPerPixel: 32))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            draw()
            NSGraphicsContext.restoreGraphicsState()
            return Data(bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let actual = try raster { ruler.drawHashMarksAndLabels(in: ruler.bounds) }
        let expected = try raster {
            NSColor(theme.color("bg-1")).setFill()
            ruler.bounds.fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            let attributes: [NSAttributedString.Key: Any] = [.font: f.view.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor(theme.color("fg-faint")), .paragraphStyle: paragraph]
            // Hand-counted source starts 0, 23, 25 become native 0, 24, 26.
            for (number, native) in [(1, 0), (2, 24), (3, 26)] {
                let fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: native), effectiveRange: nil)
                let origin = ruler.convert(NSPoint(x: 0, y: fragment.minY), from: f.view)
                let label = "\(number)" as NSString
                let height = label.size(withAttributes: attributes).height
                label.draw(in: NSRect(x: 0, y: origin.y + (fragment.height - height) / 2, width: ruler.ruleThickness - 10, height: height), withAttributes: attributes)
            }
        }
        #expect(actual == expected)
    }

    private static func configureLayout(_ view: CodeTextView, buffer: EditorBuffer, width: CGFloat, fontSize: CGFloat) {
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.setFrameSize(NSSize(width: width, height: 2000))
        buffer.storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), .ligature: 1], range: NSRange(location: 0, length: buffer.storage.length))
    }

    private static func nativeRects(_ native: NSRange, in view: CodeTextView) -> [NSRect] {
        guard let layout = view.layoutManager, let container = view.textContainer else { return [] }
        var rects: [NSRect] = []
        layout.enumerateEnclosingRects(forGlyphRange: layout.glyphRange(forCharacterRange: native, actualCharacterRange: nil), withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in rects.append(rect) }
        return rects
    }

    @MainActor
    private static func edit(line: Int, start: Int, end: Int, text: String) -> LSPJSONValue {
        .object(["range": .object(["start": .object(["line": .number(String(line)), "character": .number(String(start))]), "end": .object(["line": .number(String(line)), "character": .number(String(end))])]), "newText": .string(text)])
    }

    private static func eventually(_ description: String = "editor state", _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Timed out waiting for \(description)")
    }

    private static func stored<T>(_ name: String, in owner: Any) -> T? {
        Mirror(reflecting: owner).children.first(where: { $0.label == name })?.value as? T
    }

    private static func popover(in owner: Any) -> NSPopover? { stored("popover", in: owner) }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private static func documentationView(in window: NSWindow) -> NSTextView? {
        (window.childWindows ?? []).compactMap(\.contentView).flatMap(descendants).compactMap { $0 as? NSTextView }.first { view in
            guard let storage = view.textStorage else { return false }
            var found = false
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if String(describing: value).contains("alas-diagnostic://related") { found = true }
            }
            return found
        }
    }

    @MainActor
    final class Fixture {
        let root: URL
        let buffer: EditorBuffer
        let view: CodeTextView
        init(_ text: String) async throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: root.appendingPathComponent("test.txt"))
            buffer = EditorBuffer(worktreeRoot: root, relativePath: "test.txt")
            await buffer.awaitLoadForTesting()
            buffer.stopWatching()
            let layout = CodeEditorLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 800, height: 600))
            layout.addTextContainer(container)
            view = CodeTextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
            view.bindUndo(to: buffer)
            try view.bindDisplay(to: buffer)
            try hints(offset: min(text.utf16.count, text.first.map { String($0).utf16.count } ?? 0))
        }
        func hints(offset: Int) throws {
            try view.displayAdapter?.updateHints([.init(id: "hint", sourceOffset: offset, label: "type:", size: CGSize(width: 50, height: 16))], revision: buffer.editGeneration)
        }
        func remove() {
            try? view.bindDisplay(to: nil)
            buffer.close(persistDirtySnapshot: false)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
