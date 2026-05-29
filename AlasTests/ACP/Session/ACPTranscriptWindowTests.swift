import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscript window")
struct ACPTranscriptWindowTests {
    @Test("tailWindow is 30")
    func tailWindowConstant() {
        #expect(ACPTranscript.tailWindow == 30)
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
    }

    @Test("resetWindowToTail clamps to zero for short transcripts")
    func resetForShortTranscript() {
        let t = ACPTranscript()
        for _ in 0..<5 {
            t.messages.append(.systemNotice(id: UUID(), text: "x"))
        }
        t.resetWindowToTail()
        #expect(t.visibleHead == 0)
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
        t.stepHeadBack()
        #expect(t.visibleHead == 0) // still clamped
    }
}
