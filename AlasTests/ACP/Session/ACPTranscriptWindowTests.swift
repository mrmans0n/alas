import Foundation
import Combine
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscript window")
struct ACPTranscriptWindowTests {
    @Test("tailWindow is 30")
    func tailWindowConstant() {
        #expect(ACPTranscript.tailWindow == 30)
    }

    @Test("maxVisibleRows spans three chunks")
    func maxVisibleRowsConstant() {
        #expect(ACPTranscript.maxVisibleRows == ACPTranscript.tailWindow * 3)
    }

    @Test("visibleHead defaults to zero")
    func defaultHead() {
        let t = ACPTranscript()
        #expect(t.visibleHead == 0)
    }

    @Test("resetWindowToTail computes initial head")
    func resetForLongTranscript() {
        let t = ACPTranscript()
        for _ in 0..<50 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.resetWindowToTail()
        #expect(t.visibleHead == 20) // 50 - 30
        #expect(t.visibleTail == nil)
    }

    @Test("resetWindowToTail clamps to zero for short transcripts")
    func resetForShortTranscript() {
        let t = ACPTranscript()
        for _ in 0..<5 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.resetWindowToTail()
        #expect(t.visibleHead == 0)
        #expect(t.visibleTail == nil)
    }

    @Test("resetWindowToTail does not publish when head is already current")
    func resetDoesNotPublishWhenUnchanged() {
        let t = ACPTranscript()
        for _ in 0..<50 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.resetWindowToTail()

        var changeCount = 0
        let cancellable = t.objectWillChange.sink {
            changeCount += 1
        }

        t.resetWindowToTail()

        #expect(changeCount == 0)
        cancellable.cancel()
    }

    @Test("stepHeadBack decrements by tailWindow, clamped at zero")
    func stepBack() {
        let t = ACPTranscript()
        for _ in 0..<100 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.resetWindowToTail()
        #expect(t.visibleHead == 70)
        t.stepHeadBack()
        #expect(t.visibleHead == 40)
        t.stepHeadBack()
        #expect(t.visibleHead == 10)
        t.stepHeadBack()
        #expect(t.visibleHead == 0) // clamped
        #expect(t.visibleTail == 90)
        t.stepHeadBack()
        #expect(t.visibleHead == 0) // still clamped
        #expect(t.visibleTail == 90)
    }

    @Test("remembered anchor window caps newer rows")
    func rememberedAnchorWindowCapsNewerRows() {
        let t = ACPTranscript()
        for _ in 0..<200 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }

        t.setVisibleWindow(containing: 40)

        #expect(t.visibleHead == 40)
        #expect(t.visibleTail == 40 + ACPTranscript.maxVisibleRows)
    }

    @Test("remembered anchor near the tail keeps an explicit finite tail")
    func rememberedAnchorNearTailKeepsExplicitFiniteTail() {
        let t = ACPTranscript()
        for _ in 0..<100 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }

        t.setVisibleWindow(containing: 50)

        #expect(t.visibleHead == 50)
        #expect(t.visibleTail == 100)

        t.messages.append(.systemNotice(id: UUID(), text: "new"))

        #expect(t.visibleTail == 100)
        #expect(t.visibleTailBound == 100)
    }

    @Test("tail forward reveals newer rows and keeps a bounded window")
    func tailForwardRevealsNewerRows() {
        let t = ACPTranscript()
        for _ in 0..<200 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.setVisibleWindow(containing: 40)

        t.stepTailForward(preserving: 110)

        #expect(t.visibleTail == 160)
        #expect(t.visibleHead == 70)
        #expect(t.visibleTail! - t.visibleHead == ACPTranscript.maxVisibleRows)
    }

    @Test("tail forward keeps an older preserved anchor inside the bounded window")
    func tailForwardKeepsOlderPreservedAnchorInsideBoundedWindow() {
        let t = ACPTranscript()
        for _ in 0..<200 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.setVisibleWindow(containing: 40)

        t.stepTailForward(preserving: 50)

        #expect(t.visibleTail == 140)
        #expect(t.visibleHead == 50)
        #expect(t.visibleTail! - t.visibleHead == ACPTranscript.maxVisibleRows)
    }

    @Test("tail forward advances when preserving the top row would stall")
    func tailForwardAdvancesWhenPreservingTopRowWouldStall() {
        let t = ACPTranscript()
        for _ in 0..<200 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.setVisibleWindow(containing: 40)

        t.stepTailForward(preserving: 40)

        #expect(t.visibleTail == 160)
        #expect(t.visibleHead == 70)
        #expect(t.visibleTail! - t.visibleHead == ACPTranscript.maxVisibleRows)
    }

    @Test("prepended history shifts both sides of a bounded window")
    func prependedHistoryShiftsBoundedWindow() {
        let t = ACPTranscript()
        for _ in 0..<120 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.setVisibleWindow(containing: 10)

        t.messages.insert(contentsOf: (0..<20).map { _ in
            ACPMessage.systemNotice(id: UUID(), text: "older")
        }, at: 0)
        t.shiftVisibleHeadAfterPrepending(20)

        #expect(t.visibleHead == 30)
        #expect(t.visibleTail == 120)
    }

    @Test("prepended history preserves an explicit tail at the old end")
    func prependedHistoryPreservesExplicitTailAtOldEnd() {
        let t = ACPTranscript()
        for _ in 0..<100 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.setVisibleWindow(containing: 50)

        t.messages.insert(contentsOf: (0..<10).map { _ in
            ACPMessage.systemNotice(id: UUID(), text: "older")
        }, at: 0)
        t.shiftVisibleHeadAfterPrepending(10)

        #expect(t.visibleHead == 60)
        #expect(t.visibleTail == 110)
    }

    @Test("render window never exceeds maxVisibleRows across a mixed sequence")
    func windowStaysBoundedAcrossMixedSequence() {
        let t = ACPTranscript()
        for _ in 0..<300 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }

        func assertBounded(_ label: String) {
            let span = t.visibleTailBound - t.visibleHead
            #expect(
                span <= ACPTranscript.maxVisibleRows,
                "\(label): window span \(span) exceeded maxVisibleRows \(ACPTranscript.maxVisibleRows)"
            )
            #expect(t.visibleHead >= 0, "\(label): head went negative")
            #expect(t.visibleTailBound <= t.messages.count, "\(label): tail past end")
        }

        t.resetWindowToTail()
        assertBounded("after reset")

        t.stepHeadBack()
        assertBounded("after first step back")
        t.stepHeadBack()
        assertBounded("after second step back")

        t.setVisibleWindow(containing: 120)
        assertBounded("after anchor restore")

        // Anchor restore leaves a finite tail (120 + maxVisibleRows), so the
        // tail is not already at the end — guard that here so the following
        // step genuinely advances the window instead of hitting
        // stepTailForward's already-at-end early return.
        #expect(t.visibleTailBound < t.messages.count)
        t.stepTailForward(preserving: t.visibleHead + 5)
        assertBounded("after step forward")

        t.messages.insert(contentsOf: (0..<40).map { _ in
            ACPMessage.systemNotice(id: UUID(), text: "older")
        }, at: 0)
        t.shiftVisibleHeadAfterPrepending(40)
        assertBounded("after prepend")
    }

    @Test("freezing the tail bounds the window as messages append while paused")
    func freezeVisibleTailBoundsWindowDuringAppends() {
        let t = ACPTranscript()
        for _ in 0..<40 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.resetWindowToTail() // following the tail: head = 10, tail = nil
        #expect(t.visibleTail == nil)
        #expect(t.visibleHead == 10)

        // Pausing tail-follow freezes the tail at the current count.
        t.freezeVisibleTail()
        #expect(t.visibleTail == 40)
        #expect(t.visibleTailBound - t.visibleHead <= ACPTranscript.maxVisibleRows)

        // A long, tool-heavy turn appends far more than maxVisibleRows rows.
        for _ in 0..<200 {
            t.messages.append(.systemNotice(id: UUID(), text: "more"))
        }

        // The eager render window stays frozen/bounded instead of growing to
        // messages.count.
        #expect(t.visibleTailBound == 40)
        #expect(t.visibleTailBound - t.visibleHead <= ACPTranscript.maxVisibleRows)
    }

    @Test("freezeVisibleTail is a no-op when the tail is already finite")
    func freezeVisibleTailNoOpWhenFinite() {
        let t = ACPTranscript()
        for _ in 0..<100 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.setVisibleWindow(containing: 20) // finite tail = 100
        let tailBefore = t.visibleTail
        #expect(tailBefore != nil)

        t.freezeVisibleTail()

        #expect(t.visibleTail == tailBefore)
    }
}
