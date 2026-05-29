import Testing
import CoreGraphics
@testable import Alas

struct ACPScrollDirectionClassifierTests {
    @Test func firstSampleReportsNoChange() {
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: nil,
            newOffsetY: 0,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        #expect(decision == .noChange)
    }

    @Test func isRestoringSuppressesAllDecisions() {
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 2000,
            newOffsetY: 500,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: true
        )
        #expect(decision == .noChange)
    }

    @Test func upwardMoveAboveEpsilonPauses() {
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 1000,
            newOffsetY: 900,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        #expect(decision == .userScrolledUp)
    }

    @Test func upwardMoveBelowEpsilonIsJitter() {
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 1000,
            newOffsetY: 999.8,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        #expect(decision == .noChange)
    }

    @Test func downwardMoveStillAwayFromBottomIsNoChange() {
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 1000,
            newOffsetY: 1500,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        // contentH - viewportH - newY = 5000 - 600 - 1500 = 2900 > 36
        #expect(decision == .noChange)
    }

    @Test func reachingBottomResumes() {
        // contentH - viewportH - newY = 5000 - 600 - 4400 = 0 <= 36
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 4300,
            newOffsetY: 4400,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        #expect(decision == .userAtBottom)
    }

    @Test func withinToleranceOfBottomResumes() {
        // contentH - viewportH - newY = 5000 - 600 - 4380 = 20 <= 36
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 4300,
            newOffsetY: 4380,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        #expect(decision == .userAtBottom)
    }

    @Test func contentShorterThanViewportIsAtBottom() {
        // contentH < viewportH (short transcript): distanceFromBottom clamps to 0.
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 0,
            newOffsetY: 0,
            viewportHeight: 800,
            contentHeight: 400,
            isRestoring: false
        )
        #expect(decision == .userAtBottom)
    }

    @Test func stationaryAwayFromBottomIsNoChange() {
        // newY == prev (e.g., layout pass that didn't move offset).
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 1000,
            newOffsetY: 1000,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        #expect(decision == .noChange)
    }

    // MARK: - Boundary tests pinning upwardEpsilon and bottomTolerance

    @Test func upwardMoveAtEpsilonBoundaryIsNoChange() {
        // newY == prev - upwardEpsilon (0.5) → condition is strict `<`, so noChange.
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 1000,
            newOffsetY: 999.5,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        #expect(decision == .noChange)
    }

    @Test func upwardMoveJustPastEpsilonPauses() {
        // newY < prev - upwardEpsilon by a hair → userScrolledUp.
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 1000,
            newOffsetY: 999.49,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        #expect(decision == .userScrolledUp)
    }

    @Test func atExactBottomToleranceBoundaryResumes() {
        // contentH - viewportH - newY = 5000 - 600 - 4364 = 36 (== bottomTolerance)
        // condition is `<=`, so userAtBottom.
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 4300,
            newOffsetY: 4364,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        #expect(decision == .userAtBottom)
    }

    @Test func justOutsideBottomToleranceIsNoChange() {
        // contentH - viewportH - newY = 5000 - 600 - 4363 = 37 (> bottomTolerance) → noChange.
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 4300,
            newOffsetY: 4363,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        #expect(decision == .noChange)
    }
}
