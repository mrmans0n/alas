import AppKit
import Foundation
import Testing
@testable import Alas

// @MainActor: drives ACPMarkdownInlineNSTextView, AppKit main-thread-only APIs.
@MainActor
@Suite("ACP transcript upstream reference chips")
struct ACPUpstreamReferenceTranscriptTests {
    private let theme = Theme(id: "test", name: "Test", tokens: ["fg": "#ffffff", "fg-muted": "#aaaaaa", "accent": "#5fb7c4"])

    private func rendered(_ source: String) -> NSMutableAttributedString {
        ACPMarkdownInlineRenderer.makeAttributedString(
            source: source, theme: theme, typography: .default, role: .body
        )
    }

    @Test("summary references follow visible badges and keep first occurrence order")
    func summaryReferences() {
        let message = """
        fix #12 and #12

        `#13` [#14](https://example.com) then #15

        ```text
        #16
        ```
        """

        #expect(ACPUpstreamReferenceChip.summaryReferences(in: message, host: .github, theme: theme).map(\.spelling) == ["#12", "#15"])
    }

    @Test("rendered user text chips plain references but not inline code or links")
    func renderedExclusions() async {
        let store = await UpstreamReferenceFixtures.store()
        let text = rendered("fixes #12, not `#13` or [#14](https://example.com)")

        let count = ACPUpstreamReferenceChip.chipifyRendered(
            text, chipping: ACPUpstreamReferenceChipping(store: store, host: .github)
        )

        #expect(count == 1)
        #expect(ACPUpstreamReferenceChip.plainText(of: text) == "fixes #12, not #13 or #14")
    }

    @Test("copying a transcript selection spells chips out instead of U+FFFC")
    func transcriptCopy() async {
        let store = await UpstreamReferenceFixtures.store()
        let text = rendered("see #12 please")
        ACPUpstreamReferenceChip.chipifyRendered(text, chipping: ACPUpstreamReferenceChipping(store: store, host: .github))
        let textView = ACPMarkdownInlineNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        textView.isEditable = false
        textView.isSelectable = true
        textView.textStorage?.setAttributedString(text)
        let board = NSPasteboard(name: .init("alas-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        textView.selectAll(nil)

        #expect(textView.writeSelection(to: board, types: [.string]))
        #expect(board.string(forType: .string) == "see #12 please")
    }

    @Test("a paragraph without references never subscribes to store revisions")
    func plainParagraphSkipsStoreSubscription() async {
        let store = await UpstreamReferenceFixtures.store()
        let chipping = ACPUpstreamReferenceChipping(store: store, host: .github)

        // Mirrors exactly what `ACPMarkdownInlineTextView.updateNSView` does:
        // gate the `upstreamReferences` assignment on `chipifyRendered`'s
        // own replacement count, so a paragraph with nothing to chip never
        // installs a hover tracking area or a revision subscription.
        let plainText = rendered("nothing to see here")
        let plainCount = ACPUpstreamReferenceChip.chipifyRendered(plainText, chipping: chipping)
        let plainView = ACPMarkdownInlineNSTextView(frame: .zero)
        plainView.upstreamReferences = plainCount > 0 ? chipping.store : nil
        #expect(plainCount == 0)
        #expect(plainView.upstreamReferences == nil)

        let referencedText = rendered("see #12")
        let referencedCount = ACPUpstreamReferenceChip.chipifyRendered(referencedText, chipping: chipping)
        let referencedView = ACPMarkdownInlineNSTextView(frame: .zero)
        referencedView.upstreamReferences = referencedCount > 0 ? chipping.store : nil
        #expect(referencedCount == 1)
        #expect(referencedView.upstreamReferences === store)
    }

    @Test("a paragraph with a chip measures wider than its text alone")
    func measuresChipWidth() async {
        let store = await UpstreamReferenceFixtures.store()
        let sentence = "this is a plain paragraph of text with no reference in it"
        let plain = ACPMarkdownInlineNSTextView(frame: .zero)
        plain.textStorage?.setAttributedString(rendered(sentence))
        let chipped = ACPMarkdownInlineNSTextView(frame: .zero)
        let text = rendered("\(sentence) #12")
        ACPUpstreamReferenceChip.chipifyRendered(text, chipping: ACPUpstreamReferenceChipping(store: store, host: .github))
        chipped.textStorage?.setAttributedString(text)

        #expect(chipped.naturalFittingSize().width > plain.naturalFittingSize().width + 30)
    }

    @Test("a hover-card scroll observer does not keep the scroll view's clip view alive")
    func scrollObserverDoesNotRetainClipView() async {
        let store = await UpstreamReferenceFixtures.store()
        weak var weakScrollView: NSScrollView?
        weak var weakClipView: NSClipView?
        weak var weakOuterClipView: NSClipView?
        autoreleasepool {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            let textView = ACPMarkdownInlineNSTextView(
                frame: NSRect(x: 0, y: 0, width: 300, height: 40),
                textContainer: NSTextContainer()
            )
            let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            outer.documentView = scrollView
            scrollView.documentView = textView
            textView.upstreamReferences = store
            weakOuterClipView = outer.contentView
            weakScrollView = scrollView
            weakClipView = scrollView.contentView
        }

        // Autoreleased AppKit temporaries drain on the next run-loop turn; a
        // real retain cycle never drains, so poll against a deadline. The clip
        // view is asserted rather than the text view because AppKit keeps a
        // text view that has a superview alive on its own, independent of the
        // observer; only a retaining observer pins the clip view.
        Self.spinRunLoop(until: { weakScrollView == nil && weakClipView == nil && weakOuterClipView == nil }, timeout: 2)

        #expect(weakScrollView == nil)
        #expect(weakClipView == nil)
        #expect(weakOuterClipView == nil)
    }

    @Test("scrolling an outer scroll view hides a hover card opened inside a nested scroll view")
    func outerScrollHidesHoverCardInNestedScrollView() async throws {
        let store = await UpstreamReferenceFixtures.store()
        let chipping = ACPUpstreamReferenceChipping(store: store, host: .github)
        let text = rendered("see #12")
        ACPUpstreamReferenceChip.chipifyRendered(text, chipping: chipping)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let column = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
        let inner = NSScrollView(frame: NSRect(x: 0, y: 100, width: 400, height: 60))
        let textView = ACPMarkdownInlineNSTextView()
        textView.isEditable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(text)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        inner.documentView = textView
        column.addSubview(inner)
        outer.documentView = column
        window.contentView = outer
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        textView.upstreamReferences = store
        window.layoutIfNeeded()
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        textView.layoutSubtreeIfNeeded()
        textView.displayIfNeeded()

        let chipLocation = try #require(text.string.firstIndex(of: "\u{FFFC}")).utf16Offset(in: text.string)
        let anchor = try #require(textView.upstreamReferenceAnchorRect(for: NSRange(location: chipLocation, length: 1)))
        let point = textView.convert(NSPoint(x: anchor.midX, y: anchor.midY), to: nil)
        let move = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        func popoverCount() -> Int {
            NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }.count
        }
        let baseline = popoverCount()

        textView.mouseMoved(with: move)
        await Self.poll(until: { popoverCount() > baseline }, timeout: 3)
        #expect(popoverCount() > baseline)

        outer.contentView.setBoundsOrigin(NSPoint(x: 0, y: 40))
        await Self.poll(until: { popoverCount() == baseline }, timeout: 3)

        #expect(popoverCount() == baseline)
    }

    /// Polls with a deadline while yielding the main queue, which a hover
    /// card's `asyncAfter` needs; a nested run loop cannot drain it from
    /// inside a main-actor test.
    private static func poll(until condition: () -> Bool, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func spinRunLoop(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
