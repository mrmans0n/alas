import AppKit
import Foundation
import Testing
@testable import Alas

// @MainActor: drives ACPNSTextView/NSWindow, AppKit main-thread-only APIs.
@MainActor
@Suite("ACP composer upstream reference chips")
struct ACPUpstreamReferenceComposerTests {
    private func makeTextView(
        store: ACPUpstreamReferenceStore?,
        onSubmit: @escaping ACPComposerSubmitHandler = { _, _, _, _, _ in true }
    ) -> (ACPNSTextView, ACPInputField.Coordinator, NSWindow) {
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let window = NSWindow(contentRect: textView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(textView)
        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: URL(fileURLWithPath: "/tmp/alas"),
            initialDraft: .empty,
            focusRequest: 0,
            sendOnEnter: true,
            onDraftChange: { _ in },
            onDraftClear: {},
            onSubmit: onSubmit,
            upstreamReferences: store
        )
        coordinator.textView = textView
        textView.coordinator = coordinator
        textView.delegate = coordinator
        textView.allowsUndo = true
        window.makeFirstResponder(textView)
        return (textView, coordinator, window)
    }

    private func type(_ text: String, into textView: NSTextView) {
        for character in text {
            textView.insertText(String(character), replacementRange: textView.selectedRange())
        }
    }

    private func chipSpellings(_ textView: NSTextView) -> [String] {
        var spellings: [String] = []
        let storage = textView.attributedString()
        storage.enumerateAttribute(.upstreamReference, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let spelling = value as? String { spellings.append(spelling) }
        }
        return spellings
    }

    private func wireText(_ textView: NSTextView) -> String {
        ACPInputField.Coordinator.extract(textView.attributedString()).0
    }

    @Test("typing whitespace after a reference turns it into a chip in the same edit")
    func typedReferenceChips() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }

        type("see #12 ", into: textView)

        #expect(chipSpellings(textView) == ["#12"])
        #expect(wireText(textView) == "see #12 ")
        #expect(textView.selectedRange() == NSRange(location: textView.attributedString().length, length: 0))
        #expect(store.entry(for: CodeHostReference(sigil: .hash, number: 12)) != .idle)
    }

    @Test("undo after a typed chip restores the typed text and can be redone without crashing")
    func undoThroughTypedChips() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }
        let undoManager = textView.undoManager

        type("fix #12 and #13 now", into: textView)
        #expect(chipSpellings(textView) == ["#12", "#13"])
        #expect(undoManager?.canUndo == true)

        // The chip edit is an ordinary undoable step: undoing brings the
        // plain `#13` back, and repeatedly walking the whole history in
        // both directions must never leave a chip or a stale range behind.
        // (This used to throw `NSRangeException` out of `NSTextStorage`
        // when the chip edit bypassed NSTextView's own undo bookkeeping.)
        undoManager?.undo()
        #expect(chipSpellings(textView).count < 2)
        #expect(!textView.string.contains("\u{FFFC}\u{FFFC}"))
        while undoManager?.canUndo == true { undoManager?.undo() }
        #expect(textView.string.isEmpty)
        while undoManager?.canRedo == true { undoManager?.redo() }
        #expect(wireText(textView) == "fix #12 and #13 now")
        #expect(chipSpellings(textView) == ["#12", "#13"])
        while undoManager?.canUndo == true { undoManager?.undo() }
        #expect(textView.string.isEmpty)

        // Editing after an undo is still a normal, undoable typing session.
        type("see #14 ", into: textView)
        #expect(chipSpellings(textView) == ["#14"])
        undoManager?.undo()
        #expect(chipSpellings(textView).isEmpty)
        #expect(textView.string.hasPrefix("see #14") || textView.string.isEmpty)
    }

    @Test("a reference still being typed at send time becomes a chip before the message leaves")
    func typedReferenceChipsBeforeSend() async {
        let store = await UpstreamReferenceFixtures.store()
        // Reject the submit so `submit(_:)` does not clear the visible
        // draft — the test inspects the chip it produced right before
        // handing off to `onSubmit`, mirroring "Rejected submits keep the
        // editable draft in place" in `Coordinator.submit`'s own doc comment.
        let (textView, coordinator, window) = makeTextView(store: store, onSubmit: { _, _, _, _, _ in false })
        defer { withExtendedLifetime((coordinator, window)) {} }
        // No trailing whitespace, so no keystroke ever completed the token.
        type("see #12", into: textView)
        #expect(chipSpellings(textView).isEmpty)

        coordinator.submit(textView)

        #expect(chipSpellings(textView) == ["#12"])
    }

    @Test("punctuation typed before the space is kept, and auto-paired parens are not doubled")
    func punctuationCarriedOver() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }

        type("(#12). ", into: textView)

        #expect(chipSpellings(textView) == ["#12"])
        #expect(wireText(textView) == "(#12). ")
    }

    @Test("no store, or a token in an open code span, stays plain text")
    func noChipWithoutRemoteOrInCode() async {
        let (plain, c1, w1) = makeTextView(store: nil)
        defer { withExtendedLifetime((c1, w1)) {} }
        type("see #12 ", into: plain)
        #expect(chipSpellings(plain).isEmpty)

        let store = await UpstreamReferenceFixtures.store()
        let (code, c2, w2) = makeTextView(store: store)
        defer { withExtendedLifetime((c2, w2)) {} }
        type("`see #12 ", into: code)
        #expect(chipSpellings(code).isEmpty)
    }

    @Test("pasted text chips references, but not one glued to the word before the paste")
    func pastedReferences() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }

        #expect(textView.insertPlainText("fix #12 and #13"))
        #expect(chipSpellings(textView) == ["#12", "#13"])

        textView.string = "abc"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(textView.insertPlainText("#14"))
        #expect(chipSpellings(textView).isEmpty)
        #expect(textView.string == "abc#14")
    }

    @Test("late remote resolution chips existing text but not the token under the caret")
    func lateChipping() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }
        textView.string = "see #12 then #13"
        textView.setSelectedRange(NSRange(location: 16, length: 0))

        textView.chipUpstreamReferencesIfNeeded()

        #expect(chipSpellings(textView) == ["#12"])
        #expect(wireText(textView) == "see #12 then #13")
    }

    @Test("copy then paste of a selection keeps the reference chip")
    func copyPasteRoundTrip() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }
        type("fix #12 now", into: textView)
        #expect(chipSpellings(textView) == ["#12"])
        let board = NSPasteboard(name: .init("alas-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        textView.selectAll(nil)

        #expect(textView.writeSelection(to: board, types: textView.writablePasteboardTypes))
        #expect(board.string(forType: .string) == "fix #12 now")

        textView.string = ""
        #expect(textView.readSelection(from: board, type: ACPNSTextView.composerDraftPasteboardType))
        #expect(chipSpellings(textView) == ["#12"])
        #expect(wireText(textView) == "fix #12 now")
    }

    @Test("attaching a store chips existing text once its remote resolves, keeping undo intact")
    func attachChipsAfterResolution() async throws {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: nil)
        defer { withExtendedLifetime((coordinator, window)) {} }
        // Typed, not assigned, so the text carries its own undo record for
        // the late chip edit to coexist with.
        type("see #12 ", into: textView)
        #expect(chipSpellings(textView).isEmpty)

        coordinator.attachUpstreamReferences(store)

        let deadline = Date().addingTimeInterval(2)
        while chipSpellings(textView).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chipSpellings(textView) == ["#12"])
        #expect(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        #expect(chipSpellings(textView).isEmpty)
        #expect("see #12 ".hasPrefix(textView.string))
    }

    @Test("a shared lookup does not turn a partial trailing reference into a chip")
    func restoreSkipsCachedReferenceAtEndOfText() async {
        let store = await UpstreamReferenceFixtures.store()
        let reference = CodeHostReference(sigil: .hash, number: 12)
        // This entry may have been loaded by a transcript or another composer.
        store.ensureLoaded(reference)
        await store.waitForPendingLoads()
        #expect(store.entry(for: reference) != .idle)

        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }

        coordinator.restoreDraftForTesting(ACPComposerDraft(segments: [.text("see #12")]), into: textView)

        #expect(chipSpellings(textView).isEmpty)
        #expect(textView.string == "see #12")

        // The user finishes the number; whitespace chips the full `#123`.
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("3 ", into: textView)
        #expect(chipSpellings(textView) == ["#123"])
        #expect(wireText(textView) == "see #123 ")
    }

    @Test("restoring a draft chips every completed reference except one ending at the text's end")
    func restoreChipsCompletedReferences() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }

        coordinator.restoreDraftForTesting(ACPComposerDraft(segments: [.text("see #12 then #13")]), into: textView)

        // "#13" sits at the very end of the restored text, so it stays
        // plain text — same "might still be mid-keystroke" guard as above.
        #expect(chipSpellings(textView) == ["#12"])
        #expect(wireText(textView) == "see #12 then #13")
    }

    @Test("pasting a same-repo PR URL inserts its chip; a comment link pastes unchanged")
    func pastedURLBecomesChip() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }

        #expect(textView.insertPlainText("landed in https://github.com/mrmans0n/alas/pull/1506."))
        #expect(chipSpellings(textView) == ["#1506"])
        #expect(wireText(textView) == "landed in #1506.")

        textView.string = ""
        let comment = "https://github.com/mrmans0n/alas/pull/1506#issuecomment-1"
        #expect(textView.insertPlainText(comment))
        #expect(chipSpellings(textView).isEmpty)
        #expect(textView.string == comment)
    }

    @Test("pasting inside an open code fence does not chip a reference")
    func pastedReferenceInsideCodeFenceStaysText() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }
        textView.string = "```\nlog: "
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        #expect(textView.insertPlainText("failed in #123"))

        #expect(chipSpellings(textView).isEmpty)
        #expect(textView.string == "```\nlog: failed in #123")
    }

    @Test("a re-mounted composer restores a reference that was already chipped")
    func remountRestoresPreviouslyChippedReference() async throws {
        let store = await UpstreamReferenceFixtures.store()
        let reference = CodeHostReference(sigil: .hash, number: 12)
        store.ensureLoaded(reference)
        await store.waitForPendingLoads()
        #expect(store.entry(for: reference) != .idle)

        let (originalTextView, originalCoordinator, originalWindow) = makeTextView(store: store)
        defer { withExtendedLifetime((originalCoordinator, originalWindow)) {} }
        #expect(originalTextView.insertPlainText("see #12"))
        #expect(chipSpellings(originalTextView) == ["#12"])

        // Persistence must retain which exact draft occurrence was a chip.
        let capturedDraft = ACPInputField.Coordinator.draft(from: originalTextView.attributedString())
        let encodedDraft = try JSONEncoder().encode(capturedDraft)
        let restoredDraft = try JSONDecoder().decode(ACPComposerDraft.self, from: encodedDraft)

        let (remountedTextView, remountedCoordinator, remountedWindow) = makeTextView(store: store)
        defer { withExtendedLifetime((remountedCoordinator, remountedWindow)) {} }
        remountedCoordinator.restoreDraftForTesting(restoredDraft, into: remountedTextView)

        #expect(chipSpellings(remountedTextView) == ["#12"])
        #expect(wireText(remountedTextView) == "see #12")
    }

    @Test("edits to deferred reference markers preserve the visible text")
    func editedDeferredReferenceMarkerUsesVisibleText() {
        let (textView, coordinator, window) = makeTextView(store: nil)
        defer { withExtendedLifetime((coordinator, window)) {} }

        let reference = CodeHostReference(sigil: .hash, number: 12)
        coordinator.restoreDraftForTesting(
            ACPComposerDraft(segments: [.upstreamReference(reference)]),
            into: textView
        )
        textView.textStorage?.deleteCharacters(in: NSRange(location: 2, length: 1))

        let edited = textView.attributedString()
        #expect(textView.string == "#1")
        #expect(ACPInputField.Coordinator.draft(from: edited).plainText == "#1")
        #expect(ACPInputField.Coordinator.extract(edited).0 == "#1")
    }

    @Test("GitLab-only references stay plain on GitHub")
    func gitLabOnlyReferenceRemainsTextOnGitHub() async {
        let github = await UpstreamReferenceFixtures.store(host: .github)
        let reference = CodeHostReference(sigil: .bang, number: 12)

        let (restored, restoredCoordinator, restoredWindow) = makeTextView(store: github)
        defer { withExtendedLifetime((restoredCoordinator, restoredWindow)) {} }
        restoredCoordinator.restoreDraftForTesting(
            ACPComposerDraft(segments: [.upstreamReference(reference)]),
            into: restored
        )
        #expect(restored.string == "!12")
        #expect(chipSpellings(restored).isEmpty)
        #expect(wireText(restored) == "!12")

        let (late, lateCoordinator, lateWindow) = makeTextView(store: nil)
        defer { withExtendedLifetime((lateCoordinator, lateWindow)) {} }
        lateCoordinator.restoreDraftForTesting(
            ACPComposerDraft(segments: [.upstreamReference(reference)]),
            into: late
        )
        lateCoordinator.attachUpstreamReferences(github)
        late.chipPersistedUpstreamReferencesIfNeeded()
        #expect(late.string == "!12")
        #expect(chipSpellings(late).isEmpty)
        #expect(wireText(late) == "!12")

        let gitlab = await UpstreamReferenceFixtures.store(host: .gitlab)
        let (source, sourceCoordinator, sourceWindow) = makeTextView(store: gitlab)
        defer { withExtendedLifetime((sourceCoordinator, sourceWindow)) {} }
        #expect(source.insertPlainText("see !12"))
        #expect(chipSpellings(source) == ["!12"])

        let board = NSPasteboard(name: .init("alas-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        source.selectAll(nil)
        #expect(source.writeSelection(to: board, types: source.writablePasteboardTypes))

        let (pasted, pastedCoordinator, pastedWindow) = makeTextView(store: github)
        defer { withExtendedLifetime((pastedCoordinator, pastedWindow)) {} }
        #expect(pasted.readSelection(from: board, type: ACPNSTextView.composerDraftPasteboardType))
        #expect(pasted.string == "see !12")
        #expect(chipSpellings(pasted).isEmpty)
        #expect(wireText(pasted) == "see !12")
    }

    @Test("pasting a copied reference inside a code fence keeps it plain text")
    func pastedComposerReferenceInsideCodeFenceStaysText() async {
        let store = await UpstreamReferenceFixtures.store()
        let (source, sourceCoordinator, sourceWindow) = makeTextView(store: store)
        defer { withExtendedLifetime((sourceCoordinator, sourceWindow)) {} }
        #expect(source.insertPlainText("see #12"))
        #expect(chipSpellings(source) == ["#12"])

        let board = NSPasteboard(name: .init("alas-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        source.selectAll(nil)
        #expect(source.writeSelection(to: board, types: source.writablePasteboardTypes))

        let (target, targetCoordinator, targetWindow) = makeTextView(store: store)
        defer { withExtendedLifetime((targetCoordinator, targetWindow)) {} }
        target.string = "```\nlog: "
        target.setSelectedRange(NSRange(location: (target.string as NSString).length, length: 0))

        #expect(target.readSelection(from: board, type: ACPNSTextView.composerDraftPasteboardType))
        #expect(target.string == "```\nlog: see #12")
        #expect(chipSpellings(target).isEmpty)
        #expect(wireText(target) == "```\nlog: see #12")
    }
}
