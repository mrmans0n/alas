import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct EditorInlayLayoutTests {
    @Test func coordinatorRequestsVisibleMarginRejectsStaleResultsAndObservesSettings() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.swift")
        try Data(String(repeating: "let x = 1\n", count: 1000).utf8).write(to: file)
        let transport = FakeTransport()
        var requests: [LSPJSONValue] = []
        transport.onSend = { sent in
            guard let request = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = request["id"] else { return }
            if request["method"] == .string("initialize") {
                transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": .object(["capabilities": .object(["inlayHintProvider": .bool(true)])])]).encodedData(), as: UTF8.self))
            } else if request["method"] == .string("textDocument/inlayHint") { requests.append(request) }
        }
        let client = LSPClient(transport: transport, language: "swift", rootURI: root.lspURI)
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: [LanguageServerConfig(language: "swift", extensions: ["swift"], command: "/usr/bin/true", args: [], env: [:], rootMarkers: [], enabled: true)]), makeClient: { _, _, _, _, _ in client })
        let tabs = TabsManager(bufferStore: EditorBufferStore(rootOverride: root.appendingPathComponent("buffers")), lsp: manager, tabsDirectory: root.appendingPathComponent("tabs"), workspaceEditJournal: WorkspaceEditJournal(root: root.appendingPathComponent("journal")))
        let app = AppState(tabsManager: tabs, lspManager: manager)
        app.config.code.inlayHints = .init()
        app.config.code.inlayHintsByLanguage = [:]
        let buffer = tabs.buffer(worktreeId: "inlays", tabId: "tab", worktreeRoot: root, relativePath: "file.swift")
        await buffer.awaitLoadForTesting()
        await buffer.awaitWorkspaceEditLifecycle()
        buffer.stopWatching()
        let layout = CodeEditorLayoutManager(), container = NSTextContainer(size: CGSize(width: 800, height: 100000))
        layout.addTextContainer(container)
        let view = CodeTextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        view.isVerticallyResizable = true
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 240))
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderFront(nil)
        let coordinator = CodeEditorCoordinator(appState: app)
        coordinator.attach(textView: view, buffer: buffer, layoutManager: layout, worktreeId: "inlays", worktreeRoot: root, tabId: "tab", revealLine: nil, revealCharacter: nil, theme: try ThemeStore().current)
        defer { coordinator.detach()
        window.orderOut(nil)
        window.contentView = nil
        buffer.close(persistDirtySnapshot: false)
        transport.finish() }
        func eventually(_ stage: String, _ condition: () -> Bool) async throws {
            for _ in 0..<300 { if condition() { return }
            try await Task.sleep(for: .milliseconds(10)) }
            try #require(condition(), "Timed out at \(stage); requests=\(requests.count), status=\(String(describing: manager.documentStatus(forFile: file, worktreeRoot: root))), source=\(buffer.editGeneration), hints=\(view.displayAdapter?.document.map.hintRuns.count ?? -1)")
        }
        func reply(_ request: LSPJSONValue) throws {
            let hint = try LSPJSONValue.decode(from: Data(#"{"position":{"line":0,"character":5},"label":": Int","kind":1}"#.utf8))
            transport.deliverFrame(String(decoding: try LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": request["id"]!, "result": .array([hint])]).encodedData(), as: UTF8.self))
        }
        try await eventually("initial request") { !requests.isEmpty }
        let first = try #require(requests.first)
        let end = try #require(first["params"]?["range"]?["end"]?["line"])
        if case .number(let value) = end { #expect((Int(value) ?? 1000) < 100) }
        view.setSourceSelectedRange(NSRange(location: 0, length: 0))
        view.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        try reply(first)
        try await eventually("request after source edit") { requests.count >= 2 }
        #expect(view.displayAdapter?.document.map.hintRuns.isEmpty == true)
        try reply(requests[1])
        try await eventually("apply current response") { view.displayAdapter?.document.map.hintRuns.count == 1 }
        let retainedID = try #require(view.displayAdapter?.document.map.hintRuns.first?.hint.id)
        #expect(view.inlayAccessibilityActions?(retainedID).isEmpty == false)
        view.setSourceSelectedRange(NSRange(location: 32, length: 0))
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.displayAdapter?.document.map.hintRuns.first?.hint.id == retainedID)
        #expect(view.inlayAccessibilityActions?(retainedID).isEmpty == true)
        try await eventually("refresh retained hints") { requests.count >= 3 }
        try reply(requests[2])
        try await eventually("fresh hints replace retained visuals") {
            guard let id = view.displayAdapter?.document.map.hintRuns.first?.hint.id else { return false }
            return id != retainedID && view.inlayAccessibilityActions?(id).isEmpty == false
        }
        let revision = buffer.editGeneration
        let version = view.displayAdapter?.document.map.revision
        app.config.code.inlayHintsByLanguage["swift"] = .init(enabled: false)
        try await eventually("settings disable") { view.displayAdapter?.document.map.hintRuns.isEmpty == true }
        #expect(buffer.editGeneration == revision)
        #expect(view.displayAdapter?.document.map.revision == version)
        app.config.code.inlayHintsByLanguage["swift"] = .init()
        try await eventually("settings enable request") { requests.count >= 4 }
        try reply(requests.last!)
        try await eventually("settings enable response") { view.displayAdapter?.document.map.hintRuns.count == 1 }
        let before = requests.count
        for position in 0..<6 { view.setSourceSelectedRange(NSRange(location: position, length: 0)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(requests.count == before)
        #expect(buffer.editGeneration == revision)
    }

    @Test func labelsAtSameOffsetPreserveSourceAndIndependentHitRegions() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "א🙂bc\twrapped line"
        try Data(text.utf8).write(to: root.appendingPathComponent("test.swift"))
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "test.swift")
        await buffer.awaitLoadForTesting()
        buffer.stopWatching()
        defer { buffer.close(persistDirtySnapshot: false) }
        let manager = NSLayoutManager(), container = NSTextContainer(size: CGSize(width: 180, height: 1000))
        manager.addTextContainer(container)
        let view = CodeTextView(frame: CGRect(x: 0, y: 0, width: 180, height: 300), textContainer: container)
        view.bindUndo(to: buffer)
        try view.bindDisplay(to: buffer)
        defer { try? view.bindDisplay(to: nil) }
        let hint = try LSPInlayHint(wireValue: LSPJSONValue.decode(from: Data(#"{"position":{"line":0,"character":3},"label":[{"value":": "},{"value":"Type","tooltip":"Description"}],"paddingLeft":true,"paddingRight":true}"#.utf8)))
        let layout = EditorInlayLayout(textView: view)
        try layout.replace([hint, hint], revision: buffer.editGeneration, settings: .init())
        let runs = try #require(view.displayAdapter).document.map.hintRuns
        #expect(runs.count == 2)
        #expect(runs[0].hint.id != runs[1].hint.id)
        #expect(runs[0].hint.sourceOffset == 3)
        #expect(runs[0].hint.parts.count == 2)
        #expect(runs[0].hint.parts[0].rect.maxX <= runs[0].hint.parts[1].rect.minX)
        #expect(runs[0].hint.parts[0].rect.minX > 0)
        #expect(runs[0].hint.parts[1].rect.maxX < runs[0].hint.size.width)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: runs[0].displayOffset, length: 1), actualCharacterRange: nil)
        let frame = manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let part = runs[0].hint.parts[1].rect
        let hit = layout.hit(at: NSPoint(x: frame.minX + part.midX, y: frame.minY + part.midY))
        #expect(hit?.id == runs[0].hint.id)
        #expect(hit?.part == 1)
        var resolutions = 0
        layout.resolve = { original in
            resolutions += 1
            return original
        }
        #expect(resolutions == 0)
        _ = await layout.resolved(runs[0].hint.id)
        _ = await layout.resolved(runs[0].hint.id)
        #expect(resolutions == 1)
        var navigated = false
        layout.navigate = { _, _ in navigated = true }
        #expect(!layout.activate(.location(1), id: runs[0].hint.id))
        #expect(!navigated)
        let actionable = try LSPInlayHint(wireValue: LSPJSONValue.decode(from: Data(#"{"position":{"line":0,"character":3},"label":[{"value":"Type","location":{"uri":"file:///types.swift","range":{"start":{"line":2,"character":0},"end":{"line":2,"character":4}}},"command":{"title":"Inspect","command":"inspect","arguments":[9007199254740993]}}],"textEdits":[{"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":3}},"newText":": Type"}]}"#.utf8)))
        try layout.replace([actionable], revision: buffer.editGeneration, settings: .init())
        let actionID = try #require(view.displayAdapter?.document.map.hintRuns.first?.hint.id)
        var actions: [String] = []
        layout.navigate = { location, position in
            #expect(location.uri == "file:///types.swift")
            #expect(position.character == 3)
            actions.append("location")
        }
        layout.perform = { hint, part, edits in
            if edits { #expect(hint.textEdits?.first?.newText == ": Type")
            actions.append("edits") }
            else { #expect(part == 0)
            #expect(hint.parts[0].command?.arguments == [.number("9007199254740993")])
            actions.append("command") }
        }
        _ = await layout.resolved(actionID)
        #expect(actions.isEmpty)
        #expect(layout.activate(.location(0), id: actionID))
        #expect(layout.activate(.command(0), id: actionID))
        #expect(layout.activate(.edits, id: actionID))
        #expect(actions == ["location", "command", "edits"])
        layout.isCurrent = { false }
        #expect(!layout.activate(.command(0), id: actionID))
        #expect(!layout.activate(.edits, id: actionID))
        layout.isCurrent = { true }
        #expect(buffer.storage.string == text)
        #expect(!buffer.undoManager.canUndo)
        view.setSourceSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        view.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == text)
        #expect(view.accessibilityValue() == text)
        let revision = buffer.editGeneration
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        try layout.replace([hint], revision: revision, settings: .init())
        #expect(try #require(view.displayAdapter).document.map.hintRuns.isEmpty)
        #expect(buffer.storage.string == "x")
        #expect(await layout.resolved(runs[0].hint.id) == nil)
    }
}
