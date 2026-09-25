import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct EditorInlayLayoutTests {
    @Test func coordinatorPrefetchesChunksRejectsStaleResultsAndObservesSettings() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.swift")
        try Data(String(repeating: "let x = 1\n", count: 1000).utf8).write(to: file)
        let transport = FakeTransport()
        var requests: [LSPJSONValue] = []
        var prefetched: [LSPJSONValue] = []
        transport.onSend = { sent in
            guard let request = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = request["id"] else { return }
            if request["method"] == .string("initialize") {
                transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": .object(["capabilities": .object(["inlayHintProvider": .bool(true)])])]).encodedData(), as: UTF8.self))
            } else if request["method"] == .string("textDocument/inlayHint") {
                if request["params"]?["range"]?["start"]?["line"] == .number("0") { requests.append(request) }
                else {
                    prefetched.append(request)
                    transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": .array([])]).encodedData(), as: UTF8.self))
                }
            }
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
            // The next chunk owns a hint exactly at this request's end.
            let boundary = try LSPJSONValue.decode(from: Data(#"{"position":{"line":256,"character":0},"label":"next:"}"#.utf8))
            transport.deliverFrame(String(decoding: try LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": request["id"]!, "result": .array([hint, boundary])]).encodedData(), as: UTF8.self))
        }
        try await eventually("initial request") { !requests.isEmpty }
        let first = try #require(requests.first)
        let end = try #require(first["params"]?["range"]?["end"]?["line"])
        #expect(end == .number("256"))
        view.setSourceSelectedRange(NSRange(location: 0, length: 0))
        view.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        try reply(first)
        try await eventually("request after source edit") { requests.count >= 2 }
        #expect(view.displayAdapter?.document.map.hintRuns.isEmpty == true)
        try reply(requests[1])
        await coordinator.awaitInlayRequestsForTesting()
        #expect(view.displayAdapter?.document.map.hintRuns.count == 1)
        let retainedID = try #require(view.displayAdapter?.document.map.hintRuns.first?.hint.id)
        #expect(view.inlayAccessibilityActions?(retainedID).isEmpty == false)
        view.setSourceSelectedRange(NSRange(location: 32, length: 0))
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.displayAdapter?.document.map.hintRuns.first?.hint.id == retainedID)
        #expect(view.inlayAccessibilityActions?(retainedID).isEmpty == true)
        try await eventually("refresh retained hints") { requests.count >= 3 }
        try reply(requests[2])
        await coordinator.awaitInlayRequestsForTesting()
        // The response repeats the hint the edit did not disturb, so the
        // retained decoration is adopted as-is and only regains its anchor.
        #expect(view.inlayAccessibilityActions?(retainedID).isEmpty == false)
        #expect(view.displayAdapter?.document.map.hintRuns.first?.hint.id == retainedID)
        // rust-analyzer sends workspace/inlayHint/refresh after didChange. A
        // refresh invalidates protocol data, but the current decorations must
        // remain visible until the replacement request answers.
        var refreshProjections = 0
        let refreshObserver = NotificationCenter.default.addMainActorObserver(
            forName: .editorDisplayProjectionWillChange,
            object: view
        ) { refreshProjections += 1 }
        defer { NotificationCenter.default.removeObserver(refreshObserver) }
        let beforeServerRefresh = requests.count
        transport.deliverFrame(#"{"jsonrpc":"2.0","id":"refresh-inlays","method":"workspace/inlayHint/refresh"}"#)
        try await eventually("server refresh request") { requests.count > beforeServerRefresh }
        #expect(view.displayAdapter?.document.map.hintRuns.first?.hint.id == retainedID)
        #expect(view.inlayAccessibilityActions?(retainedID).isEmpty == true)
        #expect(refreshProjections == 0)
        try reply(requests.last!)
        await coordinator.awaitInlayRequestsForTesting()
        #expect(view.inlayAccessibilityActions?(retainedID).isEmpty == false)
        // Moving through a prefetched chunk and back must not request or
        // recreate the already-visible hints at the beginning of the file.
        let cachedID = try #require(view.displayAdapter?.document.map.hintRuns.first?.hint.id)
        let beforeScroll = requests.count
        layout.ensureLayout(for: container)
        let nextChunkY = try #require(view.sourceLineY(300))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: nextChunkY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await eventually("prefetch beyond scrolled chunk") {
            prefetched.contains { $0["params"]?["range"]?["start"]?["line"] == .number("512") }
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        await coordinator.awaitScheduledInlayRefreshForTesting()
        #expect(requests.count == beforeScroll)
        #expect(view.displayAdapter?.document.map.hintRuns.first?.hint.id == cachedID)
        typealias Response = (client: LSPClient, context: EditorRequestContext, revision: Int, generations: [EditorDocumentID: WorkspaceEditBufferGeneration])
        let origins = try #require(Mirror(reflecting: coordinator).children.first { $0.label == "inlayResponsesByPosition" }?.value as? [LSPPosition: Response])
        // A later prefetch must not retarget an existing hint's actions to
        // the newer request's context or workspace-generation snapshot.
        let origin = try #require(origins[.init(line: 0, character: 5)])
        #expect(origin.context.range.start.line == 0)
        #expect(origin.context.range.end.line == 256)
        let revision = buffer.editGeneration
        let version = view.displayAdapter?.document.map.revision
        app.config.code.inlayHintsByLanguage["swift"] = .init(enabled: false)
        try await eventually("settings disable") { view.displayAdapter?.document.map.hintRuns.isEmpty == true }
        #expect(buffer.editGeneration == revision)
        #expect(view.displayAdapter?.document.map.revision == version)
        let beforeSettingsEnable = requests.count
        app.config.code.inlayHintsByLanguage["swift"] = .init()
        try await eventually("settings enable request") { requests.count > beforeSettingsEnable }
        try reply(requests.last!)
        await coordinator.awaitInlayRequestsForTesting()
        #expect(view.displayAdapter?.document.map.hintRuns.count == 1)
        let before = requests.count
        var selectionChanges = 0
        let selectionObserver = NotificationCenter.default.addMainActorObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: view
        ) { selectionChanges += 1 }
        defer { NotificationCenter.default.removeObserver(selectionObserver) }
        for position in 0..<6 { view.setSourceSelectedRange(NSRange(location: position, length: 0)) }
        // Selection notifications and their coordinator handler run inline on
        // the main actor; unlike viewport changes, they enqueue no inlay work.
        #expect(selectionChanges == 6)
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
        let originalAttachment = view.textStorage?.attribute(.attachment, at: runs[0].displayOffset, effectiveRange: nil) as? EditorHintAttachment
        try layout.replace([hint, hint], revision: buffer.editGeneration, settings: .init())
        #expect(view.textStorage?.attribute(.attachment, at: runs[0].displayOffset, effectiveRange: nil) as? EditorHintAttachment === originalAttachment)
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

    /// A fresh response that repeats the hints a keystroke did not disturb must
    /// reuse their decorations. Rebuilding them relays out every line between
    /// the first and last hint, which reads on screen as the whole viewport
    /// blinking once per keypress.
    @Test func identicalHintsAfterAnEditReuseTheirDecorations() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = (0 ..< 40).map { "let value\($0) = compute\($0)()" }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: root.appendingPathComponent("test.swift"))
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "test.swift")
        await buffer.awaitLoadForTesting()
        buffer.stopWatching()
        defer { buffer.close(persistDirtySnapshot: false) }
        let manager = NSLayoutManager(), container = NSTextContainer(size: CGSize(width: 900, height: 100_000))
        manager.addTextContainer(container)
        let view = CodeTextView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), textContainer: container)
        view.bindUndo(to: buffer)
        try view.bindDisplay(to: buffer)
        defer { try? view.bindDisplay(to: nil) }
        let hints = try stride(from: 0, to: 40, by: 4).map { line in
            try LSPInlayHint(wireValue: LSPJSONValue.decode(from: Data(
                #"{"position":{"line":\#(line),"character":9},"label":": Int","kind":1}"#.utf8)))
        }
        let layout = EditorInlayLayout(textView: view)
        try layout.replace(hints, revision: buffer.editGeneration, settings: .init())
        let display = try #require(view.textStorage)
        func attachments() -> [String: EditorHintAttachment] {
            var result: [String: EditorHintAttachment] = [:]
            for run in view.displayAdapter?.document.map.hintRuns ?? [] {
                result[run.hint.id] = display.attribute(.attachment, at: run.displayOffset, effectiveRange: nil) as? EditorHintAttachment
            }
            return result
        }
        let before = attachments()
        #expect(before.count == hints.count)

        // Type one character on a line that carries no hint.
        let starts = EditorDisplayAdapter.lineStarts(in: buffer.storage.string)
        view.setSourceSelectedRange(NSRange(location: starts[21] + 3, length: 0))
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        let afterEdit = attachments()
        #expect(afterEdit.count == hints.count)
        #expect(afterEdit.allSatisfy { before[$0.key] === $0.value })

        var mutations = 0
        let observer = NotificationCenter.default.addMainActorObserver(forName: NSTextStorage.didProcessEditingNotification, object: display) { [weak view] in
            guard let storage = view?.textStorage, storage.editedMask.contains(.editedCharacters) else { return }
            mutations += storage.editedRange.length
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        // A projection rebuild makes every owner of temporary attributes — the
        // semantic token colors among them — drop and repaint its ranges, which
        // is the other half of the flicker this guards against.
        var projections = 0
        let projectionObserver = NotificationCenter.default.addObserver(forName: .editorDisplayProjectionWillChange, object: view, queue: .main) { _ in
            MainActor.assumeIsolated { projections += 1 }
        }
        defer { NotificationCenter.default.removeObserver(projectionObserver) }
        try layout.replace(hints, revision: buffer.editGeneration, settings: .init())
        #expect(mutations == 0)
        #expect(projections == 0)
        let afterApply = attachments()
        #expect(afterApply.count == hints.count)
        #expect(afterApply.allSatisfy { afterEdit[$0.key] === $0.value })
        // The refreshed hints are protocol anchors again, retained visuals are not.
        #expect(view.inlayAccessibilityActions?(try #require(afterApply.keys.sorted().first)).isEmpty == false)

        // `covering` names ranges still outstanding — requested but not yet
        // answered — not the whole viewport window and not what this
        // response itself answers. A response for the first of two chunks
        // must leave the still-unanswered second chunk alone instead of
        // evicting it until its own answer arrives.
        mutations = 0
        let firstHalf = NSRange(location: 0, length: starts[20])
        let secondHalf = NSRange(location: starts[20], length: buffer.storage.length - starts[20])
        projections = 0
        try layout.replace(Array(hints.prefix(5)), covering: [secondHalf], revision: buffer.editGeneration, settings: .init())
        #expect(mutations == 0)
        #expect(projections == 0)
        #expect(view.displayAdapter?.document.map.hintRuns.count == hints.count)
        // Only the answered half is actionable; the carried-over half is not.
        #expect(view.inlayAccessibilityActions?("0:9:0").isEmpty == false)
        #expect(view.inlayAccessibilityActions?("36:9:0").isEmpty == true)
        // A chunk that already answered must not keep carrying a hint the
        // server has since dropped just because its range still sits inside
        // some looser notion of "the viewport." The caller stops naming an
        // already-answered range as outstanding — modeled here by simply not
        // including firstHalf in `covering` again — so a hint missing from
        // this second answer for firstHalf disappears instead of lingering.
        try layout.replace(Array(hints[1 ..< 5]), covering: [secondHalf], revision: buffer.editGeneration, settings: .init())
        #expect(view.displayAdapter?.document.map.hintRuns.count == hints.count - 1)
        #expect(view.displayAdapter?.document.map.hintRuns.contains { $0.hint.id == "0:9:0" } == false)
        // Same shape for a chunk in the middle, whose carried-over neighbours
        // sit on both sides of the answer — both are still outstanding.
        let middle = NSRange(location: starts[12], length: starts[28] - starts[12])
        let beforeMiddle = NSRange(location: 0, length: middle.location)
        let afterMiddle = NSRange(location: NSMaxRange(middle), length: buffer.storage.length - NSMaxRange(middle))
        try layout.replace(Array(hints), revision: buffer.editGeneration, settings: .init())
        mutations = 0
        projections = 0
        try layout.replace(Array(hints[3 ..< 7]), covering: [beforeMiddle, afterMiddle], revision: buffer.editGeneration, settings: .init())
        #expect(mutations == 0)
        #expect(projections == 0)
        #expect(view.displayAdapter?.document.map.hintRuns.count == hints.count)
        // A response with no `covering` at all claims the whole document is
        // now authoritatively answered, so hints the server dropped disappear.
        try layout.replace(Array(hints.prefix(5)), revision: buffer.editGeneration, settings: .init())
        #expect(view.displayAdapter?.document.map.hintRuns.count == 5)
        // A hint entirely outside the requested window — the viewport
        // scrolled away and stopped asking about it — must not be carried
        // over either: nothing will ever answer for it again, so carrying it
        // would leave a decoration with no path to being refreshed or
        // cleared.
        try layout.replace(hints, revision: buffer.editGeneration, settings: .init())
        try layout.replace(Array(hints[3 ..< 7]), covering: [middle], revision: buffer.editGeneration, settings: .init())
        #expect(view.displayAdapter?.document.map.hintRuns.count == 4)
    }

    @Test func shiftedHintResponseReusesTheProvisionalDecoration() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("let value = 1\n".utf8).write(to: root.appendingPathComponent("test.swift"))
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "test.swift")
        await buffer.awaitLoadForTesting()
        buffer.stopWatching()
        defer { buffer.close(persistDirtySnapshot: false) }
        let manager = NSLayoutManager(), container = NSTextContainer(size: CGSize(width: 900, height: 600))
        manager.addTextContainer(container)
        let view = CodeTextView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), textContainer: container)
        view.bindUndo(to: buffer)
        try view.bindDisplay(to: buffer)
        defer { try? view.bindDisplay(to: nil) }
        func hint(character: Int) throws -> LSPInlayHint {
            try LSPInlayHint(wireValue: LSPJSONValue.decode(from: Data(
                #"{"position":{"line":0,"character":\#(character)},"label":": Int","kind":1}"#.utf8)))
        }
        let layout = EditorInlayLayout(textView: view)
        try layout.replace([try hint(character: 9)], revision: buffer.editGeneration, settings: .init())
        let originalRun = try #require(view.displayAdapter?.document.map.hintRuns.first)
        let originalAttachment = try #require(view.textStorage?.attribute(.attachment, at: originalRun.displayOffset, effectiveRange: nil) as? EditorHintAttachment)

        view.setSourceSelectedRange(NSRange(location: 9, length: 0))
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        let provisional = try #require(view.displayAdapter?.document.map.hintRuns.first)
        #expect(provisional.hint.id == originalRun.hint.id)
        #expect(provisional.hint.sourceOffset == 10)
        #expect(view.textStorage?.attribute(.attachment, at: provisional.displayOffset, effectiveRange: nil) as? EditorHintAttachment === originalAttachment)

        try layout.replace([try hint(character: 10)], revision: buffer.editGeneration, settings: .init())

        let refreshed = try #require(view.displayAdapter?.document.map.hintRuns.first)
        #expect(refreshed.hint.id == originalRun.hint.id)
        #expect(view.textStorage?.attribute(.attachment, at: refreshed.displayOffset, effectiveRange: nil) as? EditorHintAttachment === originalAttachment)
        #expect(view.inlayAccessibilityActions?(refreshed.hint.id).isEmpty == false)
    }

    /// A retained hint's id is frozen at the line/character it had when the
    /// server first reported it. `applySourceEdit` shifts its *offset* to
    /// track a newline inserted earlier in the document, but never rewrites
    /// that frozen id — so after such an edit, a still-outstanding retained
    /// hint can share its stale id with an unrelated, freshly-answered hint
    /// that now legitimately occupies that old line number. The id-based
    /// `claimed` check must not let that collision suppress the retained
    /// hint.
    @Test func retainedHintSurvivesAnIDCollisionAfterALineShiftingEdit() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = (0 ..< 10).map { "let value\($0) = compute\($0)()" }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: root.appendingPathComponent("test.swift"))
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "test.swift")
        await buffer.awaitLoadForTesting()
        buffer.stopWatching()
        defer { buffer.close(persistDirtySnapshot: false) }
        let manager = NSLayoutManager(), container = NSTextContainer(size: CGSize(width: 900, height: 100_000))
        manager.addTextContainer(container)
        let view = CodeTextView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), textContainer: container)
        view.bindUndo(to: buffer)
        try view.bindDisplay(to: buffer)
        defer { try? view.bindDisplay(to: nil) }
        func hint(line: Int) throws -> LSPInlayHint {
            try LSPInlayHint(wireValue: LSPJSONValue.decode(from: Data(
                #"{"position":{"line":\#(line),"character":9},"label":": Int","kind":1}"#.utf8)))
        }
        // The hint on line 4 is the one that will end up with a stale,
        // colliding id once the edit below shifts it to line 5.
        let shiftedHint = try hint(line: 4)
        let layout = EditorInlayLayout(textView: view)
        try layout.replace([shiftedHint], revision: buffer.editGeneration, settings: .init())
        #expect(view.displayAdapter?.document.map.hintRuns.first?.hint.id == "4:9:0")

        // Insert a newline at the very start of the document. Every hint
        // after it — including the one on line 4 — shifts down one line, but
        // `applySourceEdit` only moves its offset; its id stays "4:9:0".
        view.setSourceSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        let starts = EditorDisplayAdapter.lineStarts(in: buffer.storage.string)
        #expect(view.displayAdapter?.document.map.hintRuns.first?.hint.id == "4:9:0")
        #expect(view.displayAdapter?.document.map.hintRuns.first?.hint.sourceOffset == starts[5] + 9)

        // A fresh response now reports a hint truly at (post-edit) line 4 —
        // whatever used to sit at line 3 before the newline was inserted.
        // Its id is also "4:9:0", genuinely and correctly, since it reflects
        // the server's current, accurate position. The now-line-5 retained
        // hint is still outstanding (its own chunk hasn't answered) and must
        // survive this collision rather than silently disappear.
        let freshHint = try hint(line: 4)
        try layout.replace([freshHint], covering: [NSRange(location: starts[5], length: buffer.storage.length - starts[5])],
                           revision: buffer.editGeneration, settings: .init())
        let runs = try #require(view.displayAdapter?.document.map.hintRuns)
        #expect(runs.count == 2)
        #expect(runs.contains { $0.hint.sourceOffset == starts[4] + 9 })
        #expect(runs.contains { $0.hint.sourceOffset == starts[5] + 9 })
    }
}
