import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP composer upstream reference chips")
struct ACPUpstreamReferenceComposerTests {
    private func makeTextView(
        store: ACPUpstreamReferenceStore?
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
            onSubmit: { _, _, _, _, _ in true },
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
