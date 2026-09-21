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

    @Test("tail-first history exposes stable global message indices")
    func tailFirstHistoryExposesGlobalIndices() {
        let t = ACPTranscript()
        let tail = (0..<30).map { index in
            ACPMessage.systemNotice(id: UUID(), text: "m\(index + 170)")
        }

        t.replaceMessages(with: tail, messageIndexOffset: 170)

        #expect(t.messageIndexOffset == 170)
        #expect(t.logicalMessageCount == 200)
        #expect(t.globalIndex(forLocalIndex: 0) == 170)
        #expect(t.globalIndex(forLocalIndex: 29) == 199)
        #expect(t.globalIndex(forLocalIndex: 30) == nil)
        #expect(t.localIndex(forGlobalIndex: 169) == nil)
        #expect(t.localIndex(forGlobalIndex: 170) == 0)
        #expect(t.localIndex(forGlobalIndex: 199) == 29)
        #expect(t.localIndex(forGlobalIndex: 200) == nil)
    }

    @Test("backfill prepend preserves the logical history extent")
    func backfillPrependPreservesLogicalExtent() {
        let t = ACPTranscript()
        let tail = (0..<30).map { index in
            ACPMessage.systemNotice(id: UUID(), text: "m\(index + 170)")
        }
        let older = (0..<170).map { index in
            ACPMessage.systemNotice(id: UUID(), text: "m\(index)")
        }
        t.replaceMessages(with: tail, messageIndexOffset: 170)

        t.prependMessages(older)

        #expect(t.messageIndexOffset == 0)
        #expect(t.logicalMessageCount == 200)
        #expect(t.globalIndex(forLocalIndex: 170) == 170)
    }

    @Test("target windows preload one page and remain full near either end")
    func targetWindowsRemainBounded() {
        let t = ACPTranscript()
        t.messages = (0..<200).map { index in
            .systemNotice(id: UUID(), text: "m\(index)")
        }

        t.setVisibleWindow(around: 100)
        #expect(t.visibleHead == 70)
        #expect(t.visibleTail == 160)

        t.setVisibleWindow(around: 10)
        #expect(t.visibleHead == 0)
        #expect(t.visibleTail == 90)

        t.setVisibleWindow(around: 190)
        #expect(t.visibleHead == 110)
        #expect(t.visibleTail == 200)
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

    /// Regression test for the "short conversation, many swallowed tools"
    /// auto-scroll bug: a live turn dominated by a long run of tool calls —
    /// each individually appended, but collapsing to a single "Ran N tools"
    /// row in the UI — must not, by itself, push enough raw messages past
    /// `tailWindow` to trim genuinely short, still-relevant context (here, a
    /// user prompt and a notice) out of the render window.
    @Test("resetWindowToTail does not trim earlier context when a tool-call run alone exceeds tailWindow")
    func resetKeepsPrefixWhenToolCallRunDominatesWindow() {
        let t = ACPTranscript()
        t.messages.append(.user(id: UUID(), text: "the user's prompt", attachments: []))
        t.messages.append(.systemNotice(id: UUID(), text: "a short notice"))
        for i in 0..<43 {
            t.messages.append(.toolCall(.init(toolCallId: "tc-\(i)", title: "Tool \(i)", kind: "read", status: "completed")))
        }

        t.resetWindowToTail()

        #expect(t.visibleHead == 0)
    }

    /// A tool-call run that exceeds `tailWindow` still only counts as ONE
    /// unit, but the messages before it are budgeted normally — a run long
    /// enough, preceded by enough OTHER distinct messages, still trims once
    /// the combined budget is exhausted.
    @Test("tailWindowHead still trims once enough non-tool-call units precede the run")
    func tailWindowHeadTrimsPastEnoughPrecedingUnits() {
        var messages: [ACPMessage] = (0..<40).map { index in
            .systemNotice(id: UUID(), text: "m\(index)")
        }
        messages += (0..<10).map { i in
            .toolCall(.init(toolCallId: "tc-\(i)", title: "Tool \(i)", kind: "read", status: "completed"))
        }

        // 40 leading notices + 1 unit for the trailing tool-call run = 41
        // units total; a budget of 30 must still trim into the notices,
        // landing exactly `30 - 1` (the run's unit) notices before the end
        // of the notice run, i.e. at index 40 - 29 = 11.
        let head = ACPTranscript.tailWindowHead(messages: messages, tailWindow: 30)
        #expect(head == 11)
    }

    /// Weighting a tool-call run as one unit must never make the window
    /// bigger than it would be for an all-plain-message transcript at the
    /// same length — it only ever holds the head back (or leaves it
    /// unchanged), never advances it further.
    @Test("tailWindowHead for an all-tool-call transcript never exceeds the plain-message baseline")
    func tailWindowHeadNeverExceedsPlainBaseline() {
        let messages: [ACPMessage] = (0..<80).map { i in
            .toolCall(.init(toolCallId: "tc-\(i)", title: "Tool \(i)", kind: "read", status: "completed"))
        }
        let head = ACPTranscript.tailWindowHead(messages: messages, tailWindow: 30)
        let plainBaseline = max(0, messages.count - 30)
        #expect(head <= plainBaseline)
        #expect(head == 0) // one contiguous run costs a single unit
    }

    /// `collapsesFinishedToolCalls` is a UI-only setting this model-layer
    /// computation cannot see, so with it off (the default) every call in a
    /// run renders as its own row. An uncapped run could otherwise leave an
    /// unbounded number of raw messages inside the window regardless of
    /// `tailWindow` — reopening an unbounded-window problem, and
    /// permanently exempting that run's messages from
    /// `trimHiddenMessages`'s off-window content truncation. A single run
    /// must therefore only ever absorb up to `tailWindow * maxVisibleRows`
    /// raw messages for free.
    @Test("a pathologically long tool-call run is still bounded by tailWindow * maxVisibleRows")
    func tailWindowHeadCapsAPathologicallyLongRun() {
        let runLength = ACPTranscript.tailWindow * ACPTranscript.maxVisibleRows + 300
        let messages: [ACPMessage] = (0..<runLength).map { i in
            .toolCall(.init(toolCallId: "tc-\(i)", title: "Tool \(i)", kind: "read", status: "completed"))
        }

        let head = ACPTranscript.tailWindowHead(messages: messages)

        #expect(head == 300)
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

    @Test("stepHeadBack(boundTail: false) keeps the tail while revealing older rows")
    func unboundedHeadStepKeepsTail() {
        let t = ACPTranscript()
        for _ in 0..<200 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.resetWindowToTail()          // head 170, tail nil
        t.freezeVisibleTail()          // tail 200
        for _ in 0..<5 { t.stepHeadBack(boundTail: false) }
        #expect(t.visibleHead == 20)   // 170 - 5*30
        #expect(t.visibleTailBound == 200)  // never trimmed
    }

    @Test("stepHeadBack default still bounds the tail to maxVisibleRows")
    func boundedHeadStepUnchanged() {
        let t = ACPTranscript()
        for _ in 0..<200 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.resetWindowToTail()
        t.freezeVisibleTail()
        for _ in 0..<5 { t.stepHeadBack() }
        #expect(t.visibleHead == 20)
        #expect(t.visibleTailBound == 20 + ACPTranscript.maxVisibleRows)
    }

    @Test("stepTailForward(boundHead: false) keeps the head while revealing newer rows")
    func unboundedTailStepKeepsHead() {
        let t = ACPTranscript()
        for _ in 0..<200 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.setVisibleWindow(containing: 0)   // head 0, tail 90
        t.stepTailForward(preserving: nil, boundHead: false)
        #expect(t.visibleHead == 0)
        #expect(t.visibleTailBound == 120)  // 90 + tailWindow
    }
}
