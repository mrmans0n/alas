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

    @Test func isRestoringSuppressesDownwardRestoreDecisions() {
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 500,
            newOffsetY: 2000,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: true
        )
        #expect(decision == .noChange)
    }

    @Test func isRestoringStillAllowsUpwardInterrupts() {
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 2000,
            newOffsetY: 500,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: true,
            isUserDriven: true
        )
        #expect(decision == .userScrolledUp)
    }

    @Test func isRestoringUserInputMovingDownwardDoesNotPause() {
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 4300,
            newOffsetY: 4400,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: true,
            isUserDriven: true
        )
        #expect(decision == .userAtBottom)
    }

    @Test func isRestoringIgnoresProgrammaticUpwardRestores() {
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 2000,
            newOffsetY: 500,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: true,
            isUserDriven: false
        )
        #expect(decision == .noChange)
    }

    @Test func isRestoringIgnoresProgrammaticBottomHits() {
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 4300,
            newOffsetY: 4400,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: true,
            isUserDriven: false
        )
        #expect(decision == .noChange)
    }

    @Test func upwardMoveAboveEpsilonPauses() {
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 1000,
            newOffsetY: 900,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false,
            isUserDriven: true
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

    @Test func upwardClampWithinBottomToleranceStaysAtBottom() {
        // Content shrink can clamp the scroll offset upward while still at tail.
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 4400,
            newOffsetY: 4380,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        #expect(decision == .userAtBottom)
    }

    @Test func layoutInducedUpwardMoveNearTailDoesNotPause() {
        // A small upward hop near the tail should not latch auto-scroll off.
        let viewportH: CGFloat = 600
        let contentH: CGFloat = 5000
        let newY = contentH - viewportH - 80
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: newY + 20,
            newOffsetY: newY,
            viewportHeight: viewportH,
            contentHeight: contentH,
            isRestoring: false
        )
        #expect(decision == .noChange)
    }

    @Test func upwardMoveMeaningfullyAwayFromTailPauses() {
        let viewportH: CGFloat = 600
        let contentH: CGFloat = 5000
        let newY = contentH - viewportH - 180
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: newY + 20,
            newOffsetY: newY,
            viewportHeight: viewportH,
            contentHeight: contentH,
            isRestoring: false,
            isUserDriven: true
        )
        #expect(decision == .userScrolledUp)
    }

    @Test func layoutInducedUpwardMoveAwayFromTailDoesNotPause() {
        // The classic "jumps up a few lines on its own" failure: a tool card
        // above the fold finishing async layout (or restore lag) shifts the
        // viewport far from the tail with NO live scroll gesture. Without a
        // user event this must not latch auto-scroll off.
        let viewportH: CGFloat = 600
        let contentH: CGFloat = 5000
        let newY = contentH - viewportH - 180
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: newY + 20,
            newOffsetY: newY,
            viewportHeight: viewportH,
            contentHeight: contentH,
            isRestoring: false,
            isUserDriven: false
        )
        #expect(decision == .noChange)
    }

    @Test func restoringUserInputOutsideBottomTolerancePauses() {
        let viewportH: CGFloat = 600
        let contentH: CGFloat = 5000
        let newY = contentH - viewportH - 80
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: newY + 20,
            newOffsetY: newY,
            viewportHeight: viewportH,
            contentHeight: contentH,
            isRestoring: true,
            isUserDriven: true
        )
        #expect(decision == .userScrolledUp)
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
    //
    // Derive values from the classifier's constants so the tests track
    // any retune of the thresholds instead of silently passing.

    @Test func upwardMoveAtEpsilonBoundaryIsNoChange() {
        // newY == prev - upwardEpsilon → strict `<` means noChange.
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 1000,
            newOffsetY: 1000 - ACPScrollDirectionClassifier.upwardEpsilon,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false
        )
        #expect(decision == .noChange)
    }

    @Test func upwardMoveJustPastEpsilonPauses() {
        // newY just past prev - upwardEpsilon → userScrolledUp.
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 1000,
            newOffsetY: 1000 - ACPScrollDirectionClassifier.upwardEpsilon - 0.01,
            viewportHeight: 600,
            contentHeight: 5000,
            isRestoring: false,
            isUserDriven: true
        )
        #expect(decision == .userScrolledUp)
    }

    @Test func atExactBottomToleranceBoundaryResumes() {
        // distanceFromBottom == bottomTolerance → `<=` means userAtBottom.
        let viewportH: CGFloat = 600
        let contentH: CGFloat = 5000
        let newY = contentH - viewportH - ACPScrollDirectionClassifier.bottomTolerance
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 4300,
            newOffsetY: newY,
            viewportHeight: viewportH,
            contentHeight: contentH,
            isRestoring: false
        )
        #expect(decision == .userAtBottom)
    }

    @Test func justOutsideBottomToleranceIsNoChange() {
        // distanceFromBottom == bottomTolerance + 1 → outside → noChange.
        let viewportH: CGFloat = 600
        let contentH: CGFloat = 5000
        let newY = contentH - viewportH - ACPScrollDirectionClassifier.bottomTolerance - 1
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 4300,
            newOffsetY: newY,
            viewportHeight: viewportH,
            contentHeight: contentH,
            isRestoring: false
        )
        #expect(decision == .noChange)
    }

    @Test func justOutsideBottomTolerancePausesOnUserDrivenUpwardMove() {
        let viewportH: CGFloat = 600
        let contentH: CGFloat = 5000
        let newY = contentH - viewportH - ACPScrollDirectionClassifier.bottomTolerance - 1
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: newY + 10,
            newOffsetY: newY,
            viewportHeight: viewportH,
            contentHeight: contentH,
            isRestoring: false,
            isUserDriven: true
        )
        #expect(decision == .userScrolledUp)
    }
}
