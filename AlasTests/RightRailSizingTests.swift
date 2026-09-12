import Testing
@testable import Alas

struct RightRailSizingTests {
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

    private func calculate(
        availableWidth: Double,
        rightPreferredVisible: Bool,
        railWidth: Double?
    ) -> RightRailSizing.Result {
        RightRailSizing.calculate(
            availableWidth: availableWidth,
            preferredSidebarWidth: 244,
            preferredRightWidth: 320,
            sidebarPreferredVisible: true,
            rightPreferredVisible: rightPreferredVisible,
            railWidth: railWidth,
            configuration: config
        )
    }

    @Test func flagOffNeverReservesRailWidth() {
        let hidden = calculate(availableWidth: 1_200, rightPreferredVisible: false, railWidth: nil)
        #expect(hidden.railWidth == 0)
        #expect(hidden.sizing.rightVisible == false)

        let shown = calculate(availableWidth: 1_200, rightPreferredVisible: true, railWidth: nil)
        #expect(shown.railWidth == 0)
        #expect(shown.sizing.rightVisible == true)
    }

    @Test func expandedPaneKeepsTheRailInsideItsOwnWidth() {
        let result = calculate(availableWidth: 1_200, rightPreferredVisible: true, railWidth: 36)

        #expect(result.railWidth == 0)
        #expect(result.sizing.rightVisible == true)
        #expect(isApproximatelyEqual(result.sizing.rightWidth, 320))
        #expect(isApproximatelyEqual(result.sizing.centerWidth, 624))
    }

    @Test func collapsedPaneReservesTheRailAndGivesTheRestToCenter() {
        let result = calculate(availableWidth: 1_200, rightPreferredVisible: false, railWidth: 36)

        #expect(result.railWidth == 36)
        #expect(result.sizing.rightVisible == false)
        #expect(isApproximatelyEqual(result.sizing.sidebarWidth, 244))
        // 1200 − 36 rail − 6 divider − 244 sidebar
        #expect(isApproximatelyEqual(result.sizing.centerWidth, 914))
    }

    @Test func narrowWindowAutoCollapseStillReservesTheRail() {
        // Too narrow for sidebar + center + right at their minimums, so
        // ThreePaneSizing drops the right pane on its own.
        let result = calculate(availableWidth: 800, rightPreferredVisible: true, railWidth: 36)

        #expect(result.sizing.rightVisible == false)
        #expect(result.railWidth == 36)
        #expect(isApproximatelyEqual(result.sizing.sidebarWidth + result.sizing.centerWidth, 758))
    }

    @Test func aZeroOrNegativeRailWidthIsTreatedAsNoRail() {
        let result = calculate(availableWidth: 1_200, rightPreferredVisible: false, railWidth: 0)
        #expect(result.railWidth == 0)
        #expect(isApproximatelyEqual(result.sizing.centerWidth, 950))
    }
}
