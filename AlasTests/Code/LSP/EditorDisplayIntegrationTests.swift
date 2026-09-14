import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct EditorDisplayIntegrationTests {
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

    @Test func coordinatorCompletionPayloadAndImportUndoSurviveHintRefresh() async throws {
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
        var actionsRequest: LSPJSONValue?
        transport.onSend = { sent in
            guard let request = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = request["id"] else { return }
            let result: LSPJSONValue
            switch request["method"]?.stringValue {
            case "initialize":
                result = try! LSPJSONValue.decode(from: Data(#"{"capabilities":{"completionProvider":{},"definitionProvider":true,"signatureHelpProvider":{"triggerCharacters":["("]},"renameProvider":{"prepareProvider":true},"codeActionProvider":true}}"#.utf8))
            case "textDocument/completion": completionRequest = request
                return
            case "textDocument/definition": definitionRequest = request
                result = .array([])
            case "textDocument/signatureHelp": signatureRequest = request
                result = .null
            case "textDocument/prepareRename": renameRequest = request
                result = .null
            case "textDocument/codeAction": actionsRequest = request
                result = .array([])
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
        let coordinator = CodeEditorCoordinator(appState: app)
        coordinator.attach(textView: view, buffer: buffer, layoutManager: layout, worktreeId: "projection", worktreeRoot: root, tabId: "tab", revealLine: nil, revealCharacter: nil, theme: try ThemeStore().current)
        defer { coordinator.detach()
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
        let item = try LSPJSONValue.decode(from: Data(#"{"label":"print","additionalTextEdits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"import Foo\n"}]}"#.utf8))
        let response: LSPJSONValue = .object(["jsonrpc": .string("2.0"), "id": try #require(request["id"]), "result": .array([item])])
        transport.deliverFrame(String(decoding: try response.encodedData(), as: UTF8.self))
        try await Task.sleep(for: .milliseconds(150))
        view.insertTab(nil)
        for _ in 0..<200 where buffer.storage.string == "\npr" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(buffer.storage.string == "import Foo\n\nprint")
        for _ in 0..<200 where view.sourceSelectedRange != NSRange(location: 17, length: 0) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.sourceSelectedRange == NSRange(location: 17, length: 0))
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
        view.showCodeActions(nil)
        for _ in 0..<200 where renameRequest == nil || actionsRequest == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(renameRequest?["params"]?["position"]?["character"] == .number("0"))
        #expect(actionsRequest?["params"]?["range"]?["start"]?["character"] == .number("0"))
        #expect(actionsRequest?["params"]?["range"]?["end"]?["character"] == .number("2"))
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
        #expect(f.view.accessibilityValue() as? String == "a\u{FFFC}🙂b")
        #expect(f.view.accessibilitySelectedTextRange() == NSRange(location: 2, length: 2))
        #expect(f.view.accessibilitySelectedText() == "🙂")
        #expect(f.view.accessibilityString(for: NSRange(location: 1, length: 3)) == "\u{FFFC}🙂")
        f.view.setAccessibilitySelectedTextRange(NSRange(location: 4, length: 1))
        #expect(f.view.sourceSelectedRange == NSRange(location: 4, length: 1))
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
