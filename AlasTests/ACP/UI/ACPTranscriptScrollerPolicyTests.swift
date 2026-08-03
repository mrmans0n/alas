import Testing
@testable import Alas

@Suite("ACPTranscriptScroller policies")
struct ACPTranscriptScrollerPolicyTests {
    @Test("head step fires near the top during a user scroll when older rows exist")
    func headStep() {
        #expect(ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 800, isUserDriven: true, threshold: 1500))
        #expect(!ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 0, scrollY: 800, isUserDriven: true, threshold: 1500))
        #expect(!ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 2000, isUserDriven: true, threshold: 1500))
        #expect(!ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 800, isUserDriven: false, threshold: 1500))
    }

    @Test("tail step fires near the bottom when newer rows are hidden")
    func tailStep() {
        #expect(ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 900,
            isUserDriven: true, threshold: 1500))
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 200, messageCount: 200, distanceFromBottom: 900,
            isUserDriven: true, threshold: 1500))
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 5000,
            isUserDriven: true, threshold: 1500))
    }

    @Test("head step threshold scales with viewport but has a floor")
    func threshold() {
        #expect(ACPTranscriptScroller.headStepThreshold(viewportHeight: 500) == 1500)
        #expect(ACPTranscriptScroller.headStepThreshold(viewportHeight: 900) == 1800)
    }
}
