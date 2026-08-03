import AppKit
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscriptScrollerView")
struct ACPTranscriptScrollerViewTests {
    private func scroller(viewport: CGFloat = 800, document: CGFloat = 5000) -> ACPTranscriptScrollerView {
        let s = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 600, height: viewport))
        s.setDocumentHeight(document)
        s.layoutSubtreeIfNeeded()
        return s
    }

    @Test("document view is flipped so y grows downward")
    func flipped() {
        #expect(scroller().flippedDocumentView.isFlipped)
    }

    @Test("setScrollY moves the viewport and clamps to content")
    func programmaticScroll() {
        let s = scroller()
        s.setScrollY(1000)
        #expect(abs(s.scrollY - 1000) < 0.5)
        s.setScrollY(999_999)
        #expect(abs(s.scrollY - (5000 - s.viewportHeight)) < 1)
        s.setScrollY(-50)
        #expect(s.scrollY >= 0)
    }

    @Test("applyPrepend grows the document and keeps the viewport still")
    func prependCompensation() {
        let s = scroller()
        s.setScrollY(300)
        s.applyPrepend(delta: 700, newDocumentHeight: 5700)
        #expect(abs(s.scrollY - 1000) < 0.5)
        #expect(s.flippedDocumentView.frame.height == 5700)
        // The same content y-range is visible: distance from bottom unchanged.
        #expect(abs(s.distanceFromBottom - (5000 - s.viewportHeight - 300)) < 1)
    }

    @Test("scrollToBottom lands within tolerance of the bottom")
    func toBottom() {
        let s = scroller()
        s.scrollToBottom()
        #expect(s.distanceFromBottom < 1)
    }

    @Test("programmatic adjustments report isProgrammatic to onScroll")
    func programmaticReporting() {
        let s = scroller()
        var reports: [(y: CGFloat, programmatic: Bool)] = []
        s.onScroll = { _, newY, _, _, isProgrammatic in
            reports.append((newY, isProgrammatic))
        }
        s.setScrollY(400)
        #expect(reports.contains { abs($0.y - 400) < 0.5 && $0.programmatic })
        #expect(!reports.contains { !$0.programmatic })
    }
}
