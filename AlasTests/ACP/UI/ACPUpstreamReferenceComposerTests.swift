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

    @Test("typing a reference does not touch undo history, and it is still text right after typing")
    func typedReferenceStaysTextAndPreservesUndo() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }

        type("see #12 ", into: textView)

        // A hand-typed reference is not chipped at the whitespace keystroke
        // (unlike the leading command pill): chipping many references per
        // message through `replaceClearingUndo` would wipe undo history on
        // every one of them. Plain typing keeps its own undo record.
        #expect(chipSpellings(textView).isEmpty)
        #expect(wireText(textView) == "see #12 ")
        #expect(textView.undoManager?.canUndo == true)

        // Don't pin the exact coalescing granularity (AppKit groups typed
        // characters into undo steps on its own schedule) — just confirm a
        // real undo happens and a redo becomes available, proving the
        // history is intact rather than wiped by `replaceClearingUndo`.
        let lengthBeforeUndo = (textView.string as NSString).length
        textView.undoManager?.undo()
        #expect((textView.string as NSString).length < lengthBeforeUndo)
        #expect(textView.undoManager?.canRedo == true)
    }

    @Test("a typed reference becomes a chip by send time")
    func typedReferenceChipsBeforeSend() async {
        let store = await UpstreamReferenceFixtures.store()
        // Reject the submit so `submit(_:)` does not clear the visible
        // draft — the test inspects the chip it produced right before
        // handing off to `onSubmit`, mirroring "Rejected submits keep the
        // editable draft in place" in `Coordinator.submit`'s own doc comment.
        let (textView, coordinator, window) = makeTextView(store: store, onSubmit: { _, _, _, _, _ in false })
        defer { withExtendedLifetime((coordinator, window)) {} }
        type("see #12 ", into: textView)
        #expect(chipSpellings(textView).isEmpty)

        coordinator.submit(textView)

        #expect(chipSpellings(textView) == ["#12"])
        #expect(store.entry(for: CodeHostReference(sigil: .hash, number: 12)) != .idle)
    }

    @Test("punctuation typed before a reference is unaffected; it is still text after typing")
    func punctuationAroundReferenceStaysText() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store, onSubmit: { _, _, _, _, _ in false })
        defer { withExtendedLifetime((coordinator, window)) {} }

        type("(#12). ", into: textView)

        #expect(chipSpellings(textView).isEmpty)
        #expect(wireText(textView) == "(#12). ")

        coordinator.submit(textView)

        #expect(chipSpellings(textView) == ["#12"])
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
        // Typing alone no longer chips (see `typedReferenceStaysTextAndPreservesUndo`);
        // chip explicitly here so the round trip has an actual chip to
        // preserve, same as it would carry one by send time or on restore.
        textView.chipUpstreamReferencesIfNeeded()
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

    @Test("attaching a store chips existing text once its remote resolves")
    func attachChipsAfterResolution() async throws {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: nil)
        defer { withExtendedLifetime((coordinator, window)) {} }
        textView.string = "see #12 "

        coordinator.attachUpstreamReferences(store)

        let deadline = Date().addingTimeInterval(2)
        while chipSpellings(textView).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chipSpellings(textView) == ["#12"])
    }

    @Test("restoring a draft ending in a reference leaves it as text, not a chip cut off mid-digit")
    func restoreSkipsReferenceAtEndOfText() async {
        let store = await UpstreamReferenceFixtures.store()
        let (textView, coordinator, window) = makeTextView(store: store)
        defer { withExtendedLifetime((coordinator, window)) {} }

        coordinator.restoreDraftForTesting(ACPComposerDraft(segments: [.text("see #12")]), into: textView)

        #expect(chipSpellings(textView).isEmpty)
        #expect(textView.string == "see #12")

        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("3 ", into: textView)
        #expect(textView.string == "see #123 ")
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
}
