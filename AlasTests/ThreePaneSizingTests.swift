import Testing
@testable import Alas

struct ThreePaneSizingTests {
    private let config = ThreePaneSizing.Configuration(
        sidebarMin: 200,
        sidebarMax: 420,
        rightMin: 240,
        rightMax: 560,
        centerMin: 400,
        dividerWidth: 6
    )

    private func isApproximatelyEqual(_ actual: Double, _ expected: Double, tolerance: Double = 0.001) -> Bool {
        abs(actual - expected) < tolerance
    }

    @Test func wideWindowUsesPreferredWidths() {
        let result = ThreePaneSizing.calculate(
            availableWidth: 1_200,
            preferredSidebarWidth: 244,
            preferredRightWidth: 320,
            sidebarPreferredVisible: true,
            rightPreferredVisible: true,
            configuration: config
        )

        #expect(isApproximatelyEqual(result.sidebarWidth, 244))
        #expect(result.rightVisible == true)
        #expect(isApproximatelyEqual(result.rightWidth, 320))
        #expect(isApproximatelyEqual(result.centerWidth, 624))
    }

    @Test func compactWindowShrinksSidePanesProportionallyBeforeCollapsingRight() {
        let preferredSidebarWidth = 244.0
        let preferredRightWidth = 320.0
        let overflow = 76.0
        let sidebarShrinkCapacity = preferredSidebarWidth - 200.0
        let rightShrinkCapacity = preferredRightWidth - 240.0
        let totalShrinkCapacity = sidebarShrinkCapacity + rightShrinkCapacity
        let expectedSidebarWidth = preferredSidebarWidth - overflow * (sidebarShrinkCapacity / totalShrinkCapacity)
        let expectedRightWidth = preferredRightWidth - overflow * (rightShrinkCapacity / totalShrinkCapacity)

        let result = ThreePaneSizing.calculate(
            availableWidth: 900,
            preferredSidebarWidth: preferredSidebarWidth,
            preferredRightWidth: preferredRightWidth,
            sidebarPreferredVisible: true,
            rightPreferredVisible: true,
            configuration: config
        )

        #expect(result.rightVisible == true)
        #expect(isApproximatelyEqual(result.centerWidth, 400))
        #expect(result.sidebarWidth > 200)
        #expect(result.sidebarWidth < 244)
        #expect(result.rightWidth > 240)
        #expect(result.rightWidth < 320)
        #expect(isApproximatelyEqual(result.sidebarWidth, expectedSidebarWidth))
        #expect(isApproximatelyEqual(result.rightWidth, expectedRightWidth))
        #expect(isApproximatelyEqual(result.sidebarWidth + result.rightWidth, 488))
    }

    @Test func wideWindowClampsPreferredWidthsUpToMinimums() {
        let result = ThreePaneSizing.calculate(
            availableWidth: 1_200,
            preferredSidebarWidth: 100,
            preferredRightWidth: 100,
            sidebarPreferredVisible: true,
            rightPreferredVisible: true,
            configuration: config
        )

        #expect(isApproximatelyEqual(result.sidebarWidth, 200))
        #expect(result.rightVisible == true)
        #expect(isApproximatelyEqual(result.rightWidth, 240))
        #expect(isApproximatelyEqual(result.centerWidth, 748))
    }

    @Test func exactThreePaneMinimumFitKeepsRightPaneVisible() {
        let availableWidth = 200 + 240 + 400 + 2 * config.dividerWidth
        let result = ThreePaneSizing.calculate(
            availableWidth: availableWidth,
            preferredSidebarWidth: 200,
            preferredRightWidth: 240,
            sidebarPreferredVisible: true,
            rightPreferredVisible: true,
            configuration: config
        )

        #expect(result.rightVisible == true)
        #expect(isApproximatelyEqual(result.sidebarWidth, 200))
        #expect(isApproximatelyEqual(result.rightWidth, 240))
        #expect(isApproximatelyEqual(result.centerWidth, 400))
    }

    @Test func rightPaneTemporarilyCollapsesWhenThreePaneMinimumsCannotFit() {
        let result = ThreePaneSizing.calculate(
            availableWidth: 840,
            preferredSidebarWidth: 244,
            preferredRightWidth: 320,
            sidebarPreferredVisible: true,
            rightPreferredVisible: true,
            configuration: config
        )

        #expect(result.rightVisible == false)
        #expect(isApproximatelyEqual(result.rightWidth, 0))
        #expect(isApproximatelyEqual(result.sidebarWidth, 244))
        #expect(isApproximatelyEqual(result.centerWidth, 590))
    }

    @Test func manuallyHiddenRightPaneStaysHiddenEvenWithEnoughRoom() {
        let result = ThreePaneSizing.calculate(
            availableWidth: 1_200,
            preferredSidebarWidth: 244,
            preferredRightWidth: 320,
            sidebarPreferredVisible: true,
            rightPreferredVisible: false,
            configuration: config
        )

        #expect(result.rightVisible == false)
        #expect(isApproximatelyEqual(result.rightWidth, 0))
        #expect(isApproximatelyEqual(result.sidebarWidth, 244))
        #expect(isApproximatelyEqual(result.centerWidth, 950))
    }

    @Test func twoPaneModeSharesSpaceProportionallyBelowCombinedMinimum() {
        let result = ThreePaneSizing.calculate(
            availableWidth: 580,
            preferredSidebarWidth: 244,
            preferredRightWidth: 320,
            sidebarPreferredVisible: true,
            rightPreferredVisible: false,
            configuration: config
        )

        #expect(result.rightVisible == false)
        #expect(isApproximatelyEqual(result.rightWidth, 0))
        #expect(isApproximatelyEqual(result.sidebarWidth, 191.3333333333))
        #expect(isApproximatelyEqual(result.centerWidth, 382.6666666667))
    }

    @Test func twoPaneAtCenterMinimumStillKeepsSidebarVisible() {
        let availableWidth = config.centerMin + config.dividerWidth
        let result = ThreePaneSizing.calculate(
            availableWidth: availableWidth,
            preferredSidebarWidth: 244,
            preferredRightWidth: 320,
            sidebarPreferredVisible: true,
            rightPreferredVisible: false,
            configuration: config
        )

        #expect(result.rightVisible == false)
        #expect(isApproximatelyEqual(result.rightWidth, 0))
        #expect(isApproximatelyEqual(result.sidebarWidth, 133.3333333333))
        #expect(isApproximatelyEqual(result.centerWidth, 266.6666666667))
        #expect(isApproximatelyEqual(result.sidebarWidth + result.centerWidth + config.dividerWidth, availableWidth))
    }

    @Test func twoPaneJustAboveCenterMinimumKeepsSidebarVisible() {
        let availableWidth = config.centerMin + config.dividerWidth + 1
        let result = ThreePaneSizing.calculate(
            availableWidth: availableWidth,
            preferredSidebarWidth: 244,
            preferredRightWidth: 320,
            sidebarPreferredVisible: true,
            rightPreferredVisible: false,
            configuration: config
        )

        #expect(result.rightVisible == false)
        #expect(isApproximatelyEqual(result.rightWidth, 0))
        #expect(isApproximatelyEqual(result.sidebarWidth, 133.6666666667))
        #expect(isApproximatelyEqual(result.centerWidth, 267.3333333333))
        #expect(isApproximatelyEqual(result.sidebarWidth + result.centerWidth + config.dividerWidth, availableWidth))
    }

    @Test func verySmallWidthsRemainNonNegative() {
        let result = ThreePaneSizing.calculate(
            availableWidth: 120,
            preferredSidebarWidth: 244,
            preferredRightWidth: 320,
            sidebarPreferredVisible: true,
            rightPreferredVisible: true,
            configuration: config
        )

        #expect(result.sidebarWidth >= 0)
        #expect(result.centerWidth >= 0)
        #expect(result.rightWidth >= 0)
        #expect(result.rightVisible == false)
        #expect(isApproximatelyEqual(result.sidebarWidth + result.centerWidth + config.dividerWidth, 120))
    }

    @Test func nonFiniteWidthsRemainNonNegative() {
        let result = ThreePaneSizing.calculate(
            availableWidth: .nan,
            preferredSidebarWidth: .infinity,
            preferredRightWidth: -.infinity,
            sidebarPreferredVisible: true,
            rightPreferredVisible: true,
            configuration: config
        )

        #expect(result.sidebarWidth.isFinite)
        #expect(result.centerWidth.isFinite)
        #expect(result.rightWidth.isFinite)
        #expect(result.sidebarWidth >= 0)
        #expect(result.centerWidth >= 0)
        #expect(result.rightWidth >= 0)
        #expect(result.rightVisible == false)
    }

    @Test func preferredWidthsAreClampedBeforeCalculation() {
        let result = ThreePaneSizing.calculate(
            availableWidth: 1_800,
            preferredSidebarWidth: 900,
            preferredRightWidth: 900,
            sidebarPreferredVisible: true,
            rightPreferredVisible: true,
            configuration: config
        )

        #expect(isApproximatelyEqual(result.sidebarWidth, 420))
        #expect(isApproximatelyEqual(result.rightWidth, 560))
        #expect(isApproximatelyEqual(result.centerWidth, 808))
    }

    @Test func hiddenSidebarReducesToCenterRight() {
        let result = ThreePaneSizing.calculate(
            availableWidth: 1_200,
            preferredSidebarWidth: 244,
            preferredRightWidth: 320,
            sidebarPreferredVisible: false,
            rightPreferredVisible: true,
            configuration: config
        )

        #expect(result.sidebarVisible == false)
        #expect(isApproximatelyEqual(result.sidebarWidth, 0))
        #expect(result.rightVisible == true)
        #expect(isApproximatelyEqual(result.rightWidth, 320))
        #expect(isApproximatelyEqual(result.centerWidth, 874))
        // 1200 - 320 - 6 (single divider between center & right) = 874
    }

    @Test func hiddenSidebarAndHiddenRightYieldCenterOnly() {
        let result = ThreePaneSizing.calculate(
            availableWidth: 1_000,
            preferredSidebarWidth: 244,
            preferredRightWidth: 320,
            sidebarPreferredVisible: false,
            rightPreferredVisible: false,
            configuration: config
        )

        #expect(result.sidebarVisible == false)
        #expect(result.rightVisible == false)
        #expect(isApproximatelyEqual(result.sidebarWidth, 0))
        #expect(isApproximatelyEqual(result.rightWidth, 0))
        #expect(isApproximatelyEqual(result.centerWidth, 1_000))
    }

    @Test func hiddenSidebarNarrowWindowCollapsesRight() {
        // centerMin + rightMin + divider = 400 + 240 + 6 = 646.
        // 600 < 646 — the right pane must collapse, center keeps remainder.
        let result = ThreePaneSizing.calculate(
            availableWidth: 600,
            preferredSidebarWidth: 244,
            preferredRightWidth: 320,
            sidebarPreferredVisible: false,
            rightPreferredVisible: true,
            configuration: config
        )

        #expect(result.sidebarVisible == false)
        #expect(result.rightVisible == false)
        #expect(isApproximatelyEqual(result.sidebarWidth, 0))
        #expect(isApproximatelyEqual(result.rightWidth, 0))
        #expect(isApproximatelyEqual(result.centerWidth, 600))
    }

    @Test func hiddenSidebarMediumWindowShrinksRightBelowPreferred() {
        // centerMin + rightMin + divider = 400 + 240 + 6 = 646 ≤ 700 < 726 = preferredRight + centerMin + divider.
        // Right is visible but shrunk below preferred to keep center at its min.
        let result = ThreePaneSizing.calculate(
            availableWidth: 700,
            preferredSidebarWidth: 244,
            preferredRightWidth: 320,
            sidebarPreferredVisible: false,
            rightPreferredVisible: true,
            configuration: config
        )

        #expect(result.sidebarVisible == false)
        #expect(result.rightVisible == true)
        #expect(isApproximatelyEqual(result.sidebarWidth, 0))
        #expect(isApproximatelyEqual(result.rightWidth, 294))   // 700 - 6 - 400 = 294
        #expect(isApproximatelyEqual(result.centerWidth, 400))  // hits centerMin
    }
}
