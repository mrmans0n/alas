import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct EditorDisplayInputTests {
    @Test func hintResponseEditsOnlyItsDisplayExtentAndPreservesSourceSelection() async throws {
        let f = try await Fixture("prefix\nvalue\nsuffix\n")
        defer { f.remove() }
        let adapter = try #require(f.view.displayAdapter)
        try adapter.updateHints([], revision: f.buffer.editGeneration)
        f.view.setSourceSelectedRange(NSRange(location: 8, length: 3))
        let recorder = DisplayEditRecorder()
        f.document.storage.delegate = recorder
        defer { f.document.storage.delegate = nil }
        try adapter.updateHints([
            .init(id: "type", sourceOffset: 12, label: ": Int", size: CGSize(width: 35, height: 14))
        ], revision: f.buffer.editGeneration)
        #expect(recorder.requestedEdits.count == 1)
        #expect(recorder.requestedEdits.first?.range == NSRange(location: 12, length: 1))
        #expect(f.view.sourceSelectedRange == NSRange(location: 8, length: 3))
        #expect(f.buffer.storage.string == "prefix\nvalue\nsuffix\n")
        #expect(f.document.storage.string == "prefix\nvalue\u{FFFC}\nsuffix\n")
    }

    @Test func typingRetainsHintsOutsideTouchedLinesWithoutReplacingTheirAttachments() async throws {
        let f = try await Fixture("aa\nbb\ncc\n")
        defer { f.remove() }
        let adapter = try #require(f.view.displayAdapter)
        let hints = [1, 4, 7].map { EditorDisplayHint(id: "hint-\($0)", sourceOffset: $0, label: "x:", size: CGSize(width: 12, height: 16)) }
        try adapter.updateHints(hints, revision: f.buffer.editGeneration)
        let before = try #require(f.document.storage.attribute(.attachment, at: 1, effectiveRange: nil) as? EditorHintAttachment)
        let after = try #require(f.document.storage.attribute(.attachment, at: 9, effectiveRange: nil) as? EditorHintAttachment)
        let recorder = DisplayEditRecorder()
        f.document.storage.delegate = recorder
        defer { f.document.storage.delegate = nil }
        #expect(adapter.replaceSource(NSRange(location: 4, length: 0), with: "🙂\n"))
        #expect(f.buffer.storage.string == "aa\nb🙂\nb\ncc\n")
        #expect(f.document.map.hintRuns.map(\.hint.sourceOffset) == [1, 10])
        #expect(f.document.storage.string == "a\u{FFFC}a\nb🙂\nb\nc\u{FFFC}c\n")
        #expect(f.document.storage.attribute(.attachment, at: 1, effectiveRange: nil) as? EditorHintAttachment === before)
        #expect(f.document.storage.attribute(.attachment, at: 11, effectiveRange: nil) as? EditorHintAttachment === after)
        #expect(recorder.requestedEdits.count == 1)
        #expect(recorder.requestedEdits.first?.range == NSRange(location: 5, length: 3))
        #expect(adapter.sourceLineStarts == [0, 3, 7, 9, 12])
        // Joining lines invalidates hints on both sides of the removed newline.
        #expect(adapter.replaceSource(NSRange(location: 2, length: 1), with: ""))
        #expect(f.document.map.hintRuns.map(\.hint.sourceOffset) == [9])
        f.document.storage.delegate = nil
        f.buffer.undoManager.undo()
        #expect(f.document.map.hintRuns.map(\.hint.sourceOffset) == [10])
    }

    @Test func sourceEditRemovesShiftedCommandHoverUnderline() async throws {
        let f = try await Fixture("alpha beta")
        defer { f.remove() }
        let adapter = try #require(f.view.displayAdapter)
        try adapter.updateHints([], revision: f.buffer.editGeneration)
        let transport = FakeTransport()
        defer { transport.finish() }
        transport.onSend = { @Sendable sent in
            guard let frame = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = frame["id"] else { return }
            let result: LSPJSONValue = frame["method"] == .string("initialize")
                ? .object(["capabilities": .object(["definitionProvider": .bool(true)])])
                : .array([.object(["uri": .string("file:///target.swift"), "range": .object(["start": .object(["line": .number("0"), "character": .number("0")]), "end": .object(["line": .number("0"), "character": .number("1")])])])])
            transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["id": id, "result": result]).encodedData(), as: UTF8.self))
        }
        let client = LSPClient(transport: transport, language: "swift", rootURI: f.root.lspURI)
        try await client.initialize()
        let feature = HoverHighlightFeature(textView: f.view, getClient: { client }, getURI: { "file:///test.txt" })
        defer { feature.cancelAndClear() }
        let rect = try #require(f.view.sourceRects(inViewFor: NSRange(location: 7, length: 1)).first)
        feature.simulateCommandPressed()
        feature.simulateMouseMoved(at: NSPoint(x: rect.midX, y: rect.midY))
        for _ in 0..<100 where feature.lastUnderlinedRange == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(feature.lastUnderlinedRange == NSRange(location: 6, length: 4))
        #expect(adapter.replaceSource(NSRange(location: 0, length: 0), with: "x"))
        #expect(feature.lastUnderlinedRange == nil)
        #expect(f.view.layoutManager?.temporaryAttribute(.underlineStyle, atCharacterIndex: 10, effectiveRange: nil) == nil)
    }

    @Test func sourceEditsClearOwnedHighlightsWithoutErasingOtherBackgrounds() async throws {
        let layout = TemporaryClearRecorder()
        let f = try await Fixture("alpha\nbeta\nomega\n", layout: layout)
        defer { f.remove() }
        let adapter = try #require(f.view.displayAdapter)
        try adapter.updateHints([], revision: f.buffer.editGeneration)
        let semantic = EditorSemanticLayer(layoutManager: layout, theme: EditorTheme(theme: try ThemeStore().current), textView: f.view, isCurrent: { _ in true })
        let context = EditorRequestContext(document: .init(host: nil, worktreeID: "test", uri: "file:///test.txt"), version: 1, serverGeneration: UUID(), range: .init(start: .init(line: 0, character: 0), end: .init(line: 3, character: 0)))
        semantic.replace([HighlightSpan(range: NSRange(location: 6, length: 4), capture: .function)], context: context)
        layout.addTemporaryAttribute(.backgroundColor, value: NSColor.blue, forCharacterRange: NSRange(location: 6, length: 4))
        layout.addTemporaryAttribute(.backgroundColor, value: NSColor.purple, forCharacterRange: NSRange(location: 11, length: 5))
        let find = EditorFindHighlightRenderer()
        find.attach(textView: f.view)
        find.render(matches: [NSRange(location: 6, length: 4)], activeIndex: 0, inactiveColor: .yellow, activeColor: .orange)
        layout.clearedRanges = []
        #expect(adapter.replaceSource(NSRange(location: 0, length: 0), with: "x"))
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 7, effectiveRange: nil) == nil)
        #expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 7, effectiveRange: nil) as? NSColor == .blue)
        #expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 12, effectiveRange: nil) as? NSColor == .purple)
        #expect(!layout.clearedRanges.isEmpty)
        #expect(layout.clearedRanges.allSatisfy { $0 == NSRange(location: 6, length: 4) })
    }

    private final class TemporaryClearRecorder: NSLayoutManager {
        var clearedRanges: [NSRange] = []
        override func removeTemporaryAttribute(_ attrName: NSAttributedString.Key, forCharacterRange charRange: NSRange) {
            clearedRanges.append(charRange)
            super.removeTemporaryAttribute(attrName, forCharacterRange: charRange)
        }
    }

    @Test func lineOffsetsStayCurrentThroughTypingHintFallbackAndUndo() async throws {
        let f = try await Fixture("ab\ncd\n")
        defer { f.remove() }
        let adapter = try #require(f.view.displayAdapter)
        // The fixture starts with hints, so this edit takes the full projection path.
        #expect(adapter.replaceSource(NSRange(location: 1, length: 0), with: "x\n"))
        #expect(adapter.sourceLineStarts == [0, 3, 5, 8])
        let recorder = DisplayEditRecorder()
        recorder.onWillProcess = { #expect(adapter.sourceLineStarts == [0, 3, 7, 10]) }
        f.document.storage.delegate = recorder
        #expect(adapter.replaceSource(NSRange(location: 4, length: 0), with: "🙂"))
        #expect(!recorder.requestedEdits.isEmpty)
        f.document.storage.delegate = nil
        #expect(adapter.sourceLineStarts == [0, 3, 7, 10])
        f.buffer.undoManager.undo()
        #expect(f.buffer.storage.string == "ax\nb\ncd\n")
        #expect(adapter.sourceLineStarts == [0, 3, 5, 8])
        f.buffer.undoManager.undo()
        #expect(f.buffer.storage.string == "ab\ncd\n")
        #expect(adapter.sourceLineStarts == [0, 3, 6])
        f.buffer.undoManager.redo()
        #expect(adapter.sourceLineStarts == [0, 3, 5, 8])
        f.buffer.undoManager.redo()
        #expect(adapter.sourceLineStarts == [0, 3, 7, 10])
    }

    @Test func ordinaryTypingPatchesOnlyTheEditedSourceRange() async throws {
        let f = try await Fixture(String(repeating: "let value = 1\n", count: 10000))
        defer { f.remove() }
        try f.view.displayAdapter?.updateHints([], revision: f.buffer.editGeneration)
        let recorder = DisplayEditRecorder()
        f.document.storage.delegate = recorder
        defer { f.document.storage.delegate = nil }
        f.view.setSourceSelectedRange(NSRange(location: 50000, length: 0))
        f.view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(recorder.requestedEdits.count == 1)
        #expect(recorder.requestedEdits.first?.range == NSRange(location: 50000, length: 1))
        #expect(f.document.storage.string == f.buffer.storage.string)
        #expect(f.document.map.revision == f.buffer.editGeneration)
        #expect(f.view.sourceSelectedRange == NSRange(location: 50001, length: 0))
    }

    @Test func typingDuringInitialLoadPublishesDisplayWithoutAnEditCallback() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: root.appendingPathComponent("test.txt"))
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "test.txt")
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 800, height: 600))
        layout.addTextContainer(container)
        let view = CodeTextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        view.bindUndo(to: buffer)
        try view.bindDisplay(to: buffer)
        defer {
            try? view.bindDisplay(to: nil)
            buffer.close(persistDirtySnapshot: false)
            try? FileManager.default.removeItem(at: root)
        }
        var callbacks = 0
        let token = buffer.onTextEdit { _ in callbacks += 1 }
        defer { buffer.removeOnEdit(token) }
        #expect(!buffer.initialLoadFinished)
        view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(callbacks == 0)
        #expect(view.string == "x")
        #expect(view.displayAdapter?.document.map.revision == buffer.editGeneration)
        #expect(view.sourceSelectedRange == NSRange(location: 1, length: 0))
        await buffer.awaitLoadForTesting()
        #expect(buffer.storage.string == "xabc")
        #expect(view.string == "xabc")
        #expect(view.displayAdapter?.document.map.revision == buffer.editGeneration)
    }

    @Test func typingAfterHintRemovalAndUndoStillUsesCurrentSourceCoordinates() async throws {
        let f = try await Fixture("abcd")
        defer { f.remove() }
        f.view.setSourceSelectedRange(NSRange(location: 2, length: 0))
        f.view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.document.map.hintRuns.isEmpty)
        #expect(f.document.storage.string == "abXcd")
        let recorder = DisplayEditRecorder()
        f.document.storage.delegate = recorder
        defer { f.document.storage.delegate = nil }
        f.view.insertText("Y", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(recorder.requestedEdits.count == 1)
        #expect(recorder.requestedEdits.first?.range == NSRange(location: 3, length: 1))
        #expect(f.document.storage.string == "abXYcd")
        f.buffer.undoManager.undo()
        #expect(f.document.storage.string == "abcd")
        f.buffer.undoManager.redo()
        #expect(f.document.storage.string == "abXYcd")
        recorder.requestedEdits.removeAll()
        f.view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(recorder.requestedEdits.count == 1)
        #expect(recorder.requestedEdits.first?.range == NSRange(location: 4, length: 1))
        #expect(f.document.storage.string == "abXY!cd")
        #expect(f.document.map.revision == f.buffer.editGeneration)
    }

    @Test func colorUpdatesPreserveHintAttachmentsAndOnlyEditAffectedAttributes() async throws {
        let f = try await Fixture(String(repeating: "let value = 1\n", count: 10000))
        defer { f.remove() }
        let attachment = try #require(f.document.storage.attribute(.attachment, at: 1, effectiveRange: nil) as? EditorHintAttachment)
        let observer = DisplayEditRecorder()
        f.document.storage.delegate = observer
        defer { f.document.storage.delegate = nil }
        f.view.setSourceSelectedRange(NSRange(location: 50000, length: 3))
        f.view.layoutManager?.addTemporaryAttribute(.foregroundColor, value: NSColor.blue, forCharacterRange: NSRange(location: 50002, length: 3))

        f.buffer.storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 50000, length: 3))

        #expect(!observer.edits.isEmpty)
        #expect(!observer.requestedEdits.isEmpty)
        #expect(observer.requestedEdits.allSatisfy { !$0.mask.contains(.editedCharacters) && $0.range == NSRange(location: 50002, length: 3) })
        // AppKit expands attribute fixing to the containing paragraph.
        #expect(observer.edits.allSatisfy { !$0.mask.contains(.editedCharacters) && $0.range == NSRange(location: 49996, length: 14) })
        #expect(f.document.storage.attribute(.attachment, at: 1, effectiveRange: nil) as? EditorHintAttachment === attachment)
        #expect(f.document.storage.attribute(.foregroundColor, at: 50002, effectiveRange: nil) as? NSColor == .red)
        #expect(f.view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 50002, effectiveRange: nil) as? NSColor == .blue)
        #expect(f.view.sourceSelectedRange == NSRange(location: 50000, length: 3))
        #expect(!f.buffer.dirty)
    }

    private final class DisplayEditRecorder: NSObject, NSTextStorageDelegate {
        var onWillProcess: (() -> Void)?
        var edits: [(mask: NSTextStorageEditActions, range: NSRange)] = []
        var requestedEdits: [(mask: NSTextStorageEditActions, range: NSRange)] = []
        func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            onWillProcess?()
            requestedEdits.append((editedMask, editedRange))
        }
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            edits.append((editedMask, editedRange))
        }
    }

    @Test func formattingPublishesRevisionBeforeNextNativeInsertion() async throws {
        let f = try await Fixture("abcd")
        defer { f.remove() }
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 3, length: 0))])
        #expect(f.buffer.applyExplicitFormattingEdits([LSPTextEdit(range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 1)), newText: "A")]))
        #expect(f.document.map.revision == f.buffer.editGeneration)
        #expect(f.view.sourceSelectedRange == NSRange(location: 3, length: 0))
        f.view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.view.sourceString == "Abc!d")
        #expect(f.view.sourceSelectedRange == NSRange(location: 4, length: 0))
    }

    @Test func staleProjectionRejectsNativeAndExplicitSourceMutation() async throws {
        let f = try await Fixture("abcd")
        defer { f.remove() }
        try f.document.replace(source: f.buffer.storage, revision: f.buffer.editGeneration - 1, hints: [])
        f.view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        f.view.insertNewline(nil)
        f.view.insertTab(nil)
        f.view.deleteBackward(nil)
        f.view.deleteWordForward(nil)
        #expect(!f.view.replaceSource(range: NSRange(location: 0, length: 0), with: "?"))
        #expect(f.view.sourceString == "abcd")
        #expect(!f.buffer.undoManager.canUndo)
    }

    @Test func cutPreservesCollapsedSecondaryCaretsAndTheirText() async throws {
        let f = try await Fixture("abcd")
        defer { f.remove() }
        let selections = [NSValue(range: NSRange(location: 0, length: 1)), NSValue(range: NSRange(location: 3, length: 0))]
        f.view.setSourceSelectedRanges(selections)
        f.view.cut(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "a")
        #expect(f.view.sourceString == "bcd")
        #expect(f.view.sourceSelectedRanges == [NSValue(range: NSRange(location: 0, length: 0)), NSValue(range: NSRange(location: 2, length: 0))])
        f.buffer.undoManager.undo()
        #expect(f.view.sourceString == "abcd")
        #expect(f.view.sourceSelectedRanges == selections)
        f.buffer.undoManager.redo()
        #expect(f.view.sourceString == "bcd")
    }

    @Test(arguments: [false, true]) func typingIntoEmptySourceRetainsConfiguredFont(deleteFirst: Bool) async throws {
        let f = try await Fixture(deleteFirst ? "abcd" : "")
        defer { f.remove() }
        let font = NSFont.monospacedSystemFont(ofSize: 19, weight: .regular)
        f.view.font = font
        f.view.typingAttributes = [.font: font, .foregroundColor: NSColor.red]
        if deleteFirst {
            f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 0, length: 4))])
            f.view.deleteBackward(nil)
        }
        f.view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.buffer.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == font)
        #expect(f.document.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == font)
        #expect(f.document.storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .red)
    }

    @Test func canonicalEquivalentReplacementIsAnExactSourceEdit() async throws {
        let f = try await Fixture("éx")
        defer { f.remove() }
        #expect(f.view.replaceSource(range: NSRange(location: 0, length: 1), with: "e\u{301}"))
        #expect(Array(f.view.sourceString.utf16) == Array("e\u{301}x".utf16))
        #expect(f.buffer.dirty)
        f.buffer.undoManager.undo()
        #expect(Array(f.view.sourceString.utf16) == Array("éx".utf16))
        #expect(!f.buffer.dirty)
        f.buffer.undoManager.redo()
        #expect(Array(f.view.sourceString.utf16) == Array("e\u{301}x".utf16))
    }

    @Test func rawSourceEditsRejectSurrogateBoundaries() async throws {
        let f = try await Fixture("a🙂x")
        defer { f.remove() }
        #expect(!f.view.replaceSource(range: NSRange(location: 2, length: 0), with: "!"))
        #expect(!f.view.replaceSource(range: NSRange(location: 1, length: 1), with: ""))
        #expect(f.view.sourceString == "a🙂x")
    }

    @Test(arguments: [false, true], ["e\u{301}y", "e\u{301}x"]) func compositionRestoresExactUnicode(cancel: Bool, final: String) async throws {
        let f = try await Fixture("éx")
        defer { f.remove() }
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 0, length: 2))])
        f.view.setMarkedText(final, selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(Array(f.view.sourceString.utf16) == Array(final.utf16))
        if cancel {
            f.view.cancelOperation(nil)
        } else {
            f.view.unmarkText()
            f.buffer.undoManager.undo()
        }
        #expect(Array(f.view.sourceString.utf16) == Array("éx".utf16))
        if !cancel {
            f.buffer.undoManager.redo()
            #expect(Array(f.view.sourceString.utf16) == Array(final.utf16))
        }
    }

    @Test func nativeReplacementChangesOnlySourceAndUndoSurvivesHints() async throws {
        let f = try await Fixture("a🙂b")
        defer { f.remove() }
        f.view.autoPairDisabled = true
        f.view.insertText("X", replacementRange: NSRange(location: 1, length: 4))
        #expect(f.buffer.storage.string == "aXb")
        f.buffer.undoManager.undo()
        #expect(f.buffer.storage.string == "a🙂b")
        #expect(!f.buffer.undoManager.canUndo)
    }

    @Test func hintOnlyDeletionDoesNotDeleteAdjacentSource() async throws {
        let f = try await Fixture("a🙂b")
        defer { f.remove() }
        f.view.setSelectedRange(NSRange(location: 1, length: 2))
        f.view.deleteBackward(nil)
        #expect(f.buffer.storage.string == "a🙂b")
        #expect(!f.buffer.undoManager.canUndo)
        #expect(f.view.string == "a\u{FFFC}\u{FFFC}🙂b")
    }

    @Test func compositionCapturesOriginalSourceAndRetainsAttributedClauses() async throws {
        let f = try await Fixture("a🙂b")
        defer { f.remove() }
        f.view.setSelectedRange(NSRange(location: 1, length: 4))
        let font = NSFont.monospacedSystemFont(ofSize: 19, weight: .regular)
        f.view.typingAttributes = [.font: font]
        let marked = NSAttributedString(string: "かな", attributes: [.markedClauseSegment: 1, .underlineStyle: 2, .font: NSFont.systemFont(ofSize: 8)])
        f.view.setMarkedText(marked, selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 4))
        #expect(f.buffer.storage.string == "aかなb")
        #expect(f.view.selectedRange() == NSRange(location: 2, length: 0))
        #expect(f.view.textStorage?.attribute(.markedClauseSegment, at: 1, effectiveRange: nil) as? Int == 1)
        #expect(!f.buffer.undoManager.canUndo)
        f.view.insertText("漢字", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.buffer.storage.string == "a漢字b")
        #expect((f.buffer.storage.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.pointSize == font.pointSize)
        #expect(f.buffer.storage.attribute(.markedClauseSegment, at: 1, effectiveRange: nil) == nil)
        #expect(f.buffer.storage.attribute(.underlineStyle, at: 1, effectiveRange: nil) == nil)
        f.buffer.undoManager.undo()
        #expect(f.buffer.storage.string == "a🙂b")
        #expect(!f.buffer.undoManager.canUndo)
        f.buffer.undoManager.redo()
        #expect(f.buffer.storage.string == "a漢字b")
    }

    @Test func hintRefreshAndSourceAttributesKeepTypingGroupAndFreshness() async throws {
        let f = try await Fixture("ab")
        defer { f.remove() }
        f.view.autoPairDisabled = true
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 2, length: 0))])
        f.view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        var changes = 0
        var selections = 0
        f.view.completionChangeHandler = { _ in changes += 1 }
        f.view.completionSelectionChangeHandler = { selections += 1 }
        let generation = f.buffer.editGeneration
        try f.refreshHints()
        f.buffer.storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 1))
        #expect(f.buffer.editGeneration == generation)
        #expect(changes == 0)
        #expect(selections == 0)
        #expect(f.view.sourceSelectedRange == NSRange(location: 3, length: 0))
        #expect(f.document.storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .red)
        f.view.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.buffer.storage.string == "abxy")
        f.buffer.undoManager.undo()
        #expect(f.buffer.storage.string == "ab")
        #expect(!f.buffer.undoManager.canUndo)
    }

    @Test func clipboardExportsSourceIncludingLiteralAttachmentCharacterAndImportsPlainText() async throws {
        let f = try await Fixture("a🙂\u{FFFC}b")
        defer { f.remove() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        f.view.setSelectedRange(NSRange(location: 0, length: 7))
        #expect(f.view.writeSelection(to: board, types: [.string, .rtf]))
        #expect(board.string(forType: .string) == "a🙂\u{FFFC}b")
        board.clearContents()
        board.setString("paste", forType: .string)
        #expect(f.view.readSelection(from: board, type: .string))
        #expect(f.view.sourceString == "paste")
        f.buffer.undoManager.undo()
        #expect(f.view.sourceString == "a🙂\u{FFFC}b")
    }

    @Test(arguments: ["transpose:", "uppercaseWord:", "deleteWordForward:"])
    func nativeTextDerivedCommandsNeverCopyVirtualCharacters(selector: String) async throws {
        let f = try await Fixture("ab")
        defer { f.remove() }
        let selection = selector == "transpose:" ? NSRange(location: 1, length: 0) : NSRange(location: 0, length: selector == "uppercaseWord:" ? 2 : 0)
        f.view.setSourceSelectedRanges([NSValue(range: selection)])
        #expect(f.view.tryToPerform(NSSelectorFromString(selector), with: nil))
        let expected = selector == "transpose:" ? "ba" : selector == "uppercaseWord:" ? "AB" : ""
        #expect(f.view.sourceString == expected)
        f.buffer.undoManager.undo()
        #expect(f.view.sourceString == "ab")
        #expect(f.view.sourceSelectedRange == selection)
    }

    @Test func pluralValidationUsesOneCapturedMapAndOneUndoGroup() async throws {
        let f = try await Fixture("a🙂b")
        defer { f.remove() }
        #expect(!f.view.shouldChangeText(inRanges: [NSValue(range: NSRange(location: 0, length: 1)), NSValue(range: NSRange(location: 5, length: 1))], replacementStrings: ["A", "B"]))
        #expect(f.view.sourceString == "A🙂B")
        f.buffer.undoManager.undo()
        #expect(f.view.sourceString == "a🙂b")
        #expect(!f.buffer.undoManager.canUndo)
    }

    @Test func compositionCancelAndForeignEditsPreserveOwnership() async throws {
        let f = try await Fixture("a🙂b")
        defer { f.remove() }
        f.view.setSelectedRange(NSRange(location: 1, length: 4))
        f.view.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(throws: Error.self) { try f.buffer.beginWorkspaceEditMutation() }
        #expect(!f.view.replaceSource(range: NSRange(location: 0, length: 1), with: "foreign"))
        f.view.cancelOperation(nil)
        #expect(f.view.sourceString == "a🙂b")
        #expect(f.view.sourceSelectedRange == NSRange(location: 1, length: 2))
        #expect(!f.buffer.undoManager.canUndo)
        f.view.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        f.buffer.storage.replaceCharacters(in: NSRange(location: 0, length: f.buffer.storage.length), with: "foreign")
        #expect(!f.view.hasMarkedText())
        f.view.cancelOperation(nil)
        #expect(f.view.sourceString == "foreign")
    }

    @Test func rebindCommitsOldCompositionAndReloadInvalidatesIt() async throws {
        let f = try await Fixture("ab")
        let other = try await Fixture("new")
        defer { f.remove()
        other.remove() }
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 1, length: 0))])
        f.view.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try f.view.bindDisplay(to: other.buffer)
        #expect(f.buffer.storage.string == "a仮b")
        #expect(f.view.sourceString == "new")
        f.buffer.undoManager.undo()
        #expect(f.buffer.storage.string == "ab")
        #expect(f.view.sourceString == "new")
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 1, length: 0))])
        f.view.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = other.buffer.loadFromDiskSyncForTesting()
        #expect(!f.view.hasMarkedText())
        f.view.cancelOperation(nil)
        #expect(other.buffer.storage.string == "new")
    }

    @Test func nativeMovementSkipsHintsAndKeepsEmojiBoundaries() async throws {
        let f = try await Fixture("a🙂b\nnext")
        defer { f.remove() }
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 1, length: 0))])
        f.view.moveLeft(nil)
        #expect(f.view.sourceSelectedRange.location == 0)
        f.view.moveRight(nil)
        #expect(f.view.sourceSelectedRange.location == 1)
        f.view.moveRight(nil)
        #expect(f.view.sourceSelectedRange.location == 3)
        f.view.moveWordRight(nil)
        #expect(f.view.sourceSelectedRange.location == 4)
        f.view.moveDown(nil)
        #expect(f.view.sourceSelectedRange.location >= 5)
    }

    @Test func sourceDragMoveIsOneTransactionAndRejectsDropInsideSelection() async throws {
        let f = try await Fixture("ab cd")
        defer { f.remove() }
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 0, length: 2))])
        #expect(!f.view.moveSourceSelection(to: 1))
        #expect(f.view.moveSourceSelection(to: 5))
        #expect(f.view.sourceString == " cdab")
        f.buffer.undoManager.undo()
        #expect(f.view.sourceString == "ab cd")
        #expect(f.view.sourceSelectedRange == NSRange(location: 0, length: 2))
        f.buffer.undoManager.redo()
        #expect(f.view.sourceSelectedRange == NSRange(location: 3, length: 2))
    }

    @Test func pairingReturnAndStepOverUseSourceSelections() async throws {
        let f = try await Fixture("ab")
        defer { f.remove() }
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 1, length: 0))])
        f.view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.view.sourceString == "a()b")
        #expect(f.view.sourceSelectedRange == NSRange(location: 2, length: 0))
        f.buffer.undoManager.undo()
        f.buffer.undoManager.redo()
        #expect(f.view.sourceSelectedRange == NSRange(location: 2, length: 0))
        try f.refreshHints()
        var dismissed = 0
        f.view.completionSelectionChangeHandler = { dismissed += 1 }
        f.view.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.view.sourceString == "a()b")
        #expect(f.view.sourceSelectedRange == NSRange(location: 3, length: 0))
        #expect(dismissed == 1)
        f.view.indentationMode = .bracketAware
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 2, length: 0))])
        f.view.insertNewline(nil)
        #expect(f.view.sourceString == "a(\n    \n)b")
        #expect(f.view.sourceSelectedRange == NSRange(location: 7, length: 0))
    }

    @Test func snippetMirrorsTabBacktabAndMulticursorsRemainSourceBased() async throws {
        let expansion = try SnippetSession.parse("a${1:one} $1 ${2:two}$0")
        let f = try await Fixture(expansion.text)
        defer { f.remove() }
        f.view.startSnippet(expansion, offset: 0)
        f.view.insertText("🙂", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.view.sourceString == "a🙂 🙂 two")
        try f.refreshHints()
        f.view.insertTab(nil)
        #expect(f.view.sourceSelectedRange == NSRange(location: 7, length: 3))
        f.view.insertBacktab(nil)
        #expect(f.view.sourceSelectedRange == NSRange(location: 1, length: 2))
        f.view.endSnippet()
        f.view.autoPairDisabled = true
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 1, length: 0)), NSValue(range: NSRange(location: 4, length: 0))])
        f.view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.view.sourceString == "aX🙂 X🙂 two")
        f.buffer.undoManager.undo()
        #expect(f.view.sourceString == "a🙂 🙂 two")
    }

    @Test func compositionRefreshRetainsMarkedQueriesAndUnmarkRegistersExactlyOneInverse() async throws {
        let f = try await Fixture("a🙂b")
        defer { f.remove() }
        f.view.setMarkedText(NSAttributedString(string: "かな", attributes: [.markedClauseSegment: 2, .underlineStyle: 2]), selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 4))
        let generation = f.buffer.editGeneration
        try f.refreshHints()
        #expect(f.view.string == "aかなb")
        f.buffer.storage.addAttribute(.foregroundColor, value: NSColor.blue, range: NSRange(location: 0, length: 4))
        #expect(f.buffer.editGeneration == generation)
        var actual = NSRange(location: NSNotFound, length: 0)
        let query = f.view.attributedSubstring(forProposedRange: NSRange(location: 1, length: 2), actualRange: &actual)
        #expect(query?.string == "かな")
        #expect(actual == NSRange(location: 1, length: 2))
        #expect(query?.attribute(.markedClauseSegment, at: 0, effectiveRange: nil) as? Int == 2)
        f.view.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 2))
        f.view.unmarkText()
        #expect(f.view.sourceString == "a漢b")
        #expect(f.view.string == "a漢b") // Deferred anchors belong to the old revision.
        f.view.unmarkText()
        f.buffer.undoManager.undo()
        #expect(f.view.sourceString == "a🙂b")
        #expect(!f.buffer.undoManager.canUndo)
    }

    @Test func deadKeyPairingAndUndoDuringCompositionPreserveOriginalSelection() async throws {
        let f = try await Fixture("ab")
        defer { f.remove() }
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 1, length: 1))])
        f.view.setMarkedText("\"", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        f.view.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(f.view.sourceString == "a\"b\"")
        #expect(f.view.sourceSelectedRange == NSRange(location: 2, length: 1))
        f.buffer.undoManager.undo()
        #expect(f.view.sourceString == "ab")
        #expect(f.view.sourceSelectedRange == NSRange(location: 1, length: 1))
        f.view.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        f.buffer.undoManager.undo()
        #expect(!f.view.hasMarkedText())
        #expect(f.view.sourceString == "ab")
    }

    @Test(arguments: ["deleteWordBackward:", "deleteWordForward:", "deleteToBeginningOfLine:", "deleteToEndOfLine:", "deleteToBeginningOfParagraph:", "deleteToEndOfParagraph:", "deleteBackwardByDecomposingPreviousCharacter:"])
    func everyDeletionFamilyLeavesHintOnlySelectionUntouched(selector: String) async throws {
        let f = try await Fixture("a🙂b")
        defer { f.remove() }
        f.view.setSelectedRange(NSRange(location: 1, length: 2))
        #expect(f.view.tryToPerform(NSSelectorFromString(selector), with: nil))
        #expect(f.view.sourceString == "a🙂b")
        #expect(!f.buffer.undoManager.canUndo)
    }

    @Test func nativeValidatedAndDirectReplacementsHonorSourceAndReadOnlyGates() async throws {
        let f = try await Fixture("a🙂b")
        defer { f.remove() }
        #expect(f.view.performValidatedReplacement(in: NSRange(location: 1, length: 4), with: NSAttributedString(string: "X")))
        #expect(f.view.sourceString == "aXb")
        f.buffer.undoManager.undo()
        try f.refreshHints()
        f.view.replaceCharacters(in: NSRange(location: 1, length: 4), with: "Y")
        #expect(f.view.sourceString == "aYb")
        f.view.isEditable = false
        #expect(!f.view.performValidatedReplacement(in: NSRange(location: 0, length: 1), with: NSAttributedString(string: "bad")))
        #expect(f.view.sourceString == "aYb")
        f.view.isEditable = true
        try f.buffer.beginWorkspaceEditMutation()
        defer { f.buffer.endWorkspaceEditMutation() }
        #expect(!f.view.shouldChangeText(inRanges: [NSValue(range: NSRange(location: 0, length: 1))], replacementStrings: ["bad"]))
        #expect(f.view.sourceString == "aYb")
    }

    @Test(arguments: ["move", "copy", "cancel", "edited"])
    func nativeDragCompletionDeletesOnlyUnchangedSuccessfullyMovedSource(outcome: String) async throws {
        let f = try await Fixture("ab cd")
        defer { f.remove() }
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 0, length: 2))])
        f.view.beginSourceDrag()
        if outcome == "edited" { _ = f.view.replaceSource(range: NSRange(location: 0, length: 2), with: "new") }
        f.view.finishSourceDrag(operation: outcome == "copy" ? .copy : outcome == "cancel" ? [] : .move)
        let expected = outcome == "move" ? " cd" : outcome == "edited" ? "new cd" : "ab cd"
        #expect(f.view.sourceString == expected)
        if outcome == "move" {
            f.buffer.undoManager.undo()
            #expect(f.view.sourceString == "ab cd")
            #expect(f.view.sourceSelectedRange == NSRange(location: 0, length: 2))
        }
    }

    @Test func sameBufferRebindPreservesSourceSelectionAndDetachesOldDisplay() async throws {
        let f = try await Fixture("a🙂b")
        defer { f.remove() }
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 3, length: 1))])
        let oldDisplay = f.document.storage
        try f.view.bindDisplay(to: f.buffer)
        #expect(oldDisplay.layoutManagers.isEmpty)
        #expect(f.view.sourceSelectedRange == NSRange(location: 3, length: 1))
        #expect(f.view.string == "a🙂b")
        #expect(!f.buffer.undoManager.canUndo)
    }

    @Test func automaticReloadWaitsForUnchangedCompositionToSettle() async throws {
        let f = try await Fixture("ab")
        defer { f.remove() }
        f.view.setSourceSelectedRanges([NSValue(range: NSRange(location: 1, length: 1))])
        f.view.setMarkedText("b", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let file = f.root.appendingPathComponent("test.txt")
        try Data("disk".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        f.buffer.handleWatcherEventForTesting()
        #expect(f.view.hasMarkedText())
        #expect(f.view.sourceString == "ab")
        f.view.unmarkText()
        for _ in 0..<100 where f.view.sourceString != "disk" { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(f.view.sourceString == "disk")
        #expect(f.view.string == "disk")
        #expect(!f.buffer.undoManager.canUndo)
    }

    @Test func hintRefreshPreservesOffsetWithinAWrappedSourceLine() async throws {
        let layout = LayoutRecorder()
        let f = try await Fixture(String(repeating: "word ", count: 2000), layout: layout)
        defer { f.remove() }
        f.buffer.storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: NSRange(location: 0, length: f.buffer.storage.length))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 120))
        f.view.setFrameSize(NSSize(width: 800, height: 1200))
        scroll.documentView = f.view
        if let container = f.view.textContainer { f.view.layoutManager?.ensureLayout(for: container) }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 150))
        let before = scroll.contentView.bounds.origin.y
        #expect(before > 100)
        layout.wholeContainerLayouts = 0
        try f.refreshHints()
        #expect(abs(scroll.contentView.bounds.origin.y - before) < 1)
        #expect(layout.wholeContainerLayouts == 0)
    }

    private final class LayoutRecorder: NSLayoutManager {
        var wholeContainerLayouts = 0
        override func ensureLayout(for container: NSTextContainer) {
            wholeContainerLayouts += 1
            super.ensureLayout(for: container)
        }
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let buffer: EditorBuffer
        let view: CodeTextView
        var document: EditorDisplayDocument { view.displayAdapter!.document }
        init(_ text: String, layout: NSLayoutManager = NSLayoutManager()) async throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: root.appendingPathComponent("test.txt"))
            buffer = EditorBuffer(worktreeRoot: root, relativePath: "test.txt")
            await buffer.awaitLoadForTesting()
            buffer.stopWatching()
            let container = NSTextContainer(size: CGSize(width: 800, height: 600))
            layout.addTextContainer(container)
            view = CodeTextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
            view.bindUndo(to: buffer)
            try view.bindDisplay(to: buffer)
            if !text.isEmpty { try refreshHints() }
        }
        func refreshHints() throws {
            try view.displayAdapter?.updateHints([
                .init(id: "one", sourceOffset: 1, label: "x:", size: CGSize(width: 12, height: 16)),
                .init(id: "two", sourceOffset: 1, label: "type:", size: CGSize(width: 40, height: 16))
            ], revision: buffer.editGeneration)
        }
        func remove() {
            try? view.bindDisplay(to: nil)
            buffer.close(persistDirtySnapshot: false)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
