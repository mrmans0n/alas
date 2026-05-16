import Foundation

enum ThreePaneSizing {
    struct Configuration: Equatable {
        var sidebarMin: Double
        var sidebarMax: Double
        var rightMin: Double
        var rightMax: Double
        var centerMin: Double
        var dividerWidth: Double
    }

    struct Result: Equatable {
        var sidebarWidth: Double
        var centerWidth: Double
        var rightWidth: Double
        var rightVisible: Bool
    }

    static func calculate(
        availableWidth rawAvailableWidth: Double,
        preferredSidebarWidth rawPreferredSidebarWidth: Double,
        preferredRightWidth rawPreferredRightWidth: Double,
        rightPreferredVisible: Bool,
        configuration: Configuration
    ) -> Result {
        let availableWidth = finiteNonNegative(rawAvailableWidth)
        let dividerWidth = finiteNonNegative(configuration.dividerWidth)
        let centerMin = finiteNonNegative(configuration.centerMin)
        let sidebarMin = finiteNonNegative(configuration.sidebarMin)
        let sidebarMax = max(sidebarMin, finiteNonNegative(configuration.sidebarMax))
        let rightMin = finiteNonNegative(configuration.rightMin)
        let rightMax = max(rightMin, finiteNonNegative(configuration.rightMax))

        let preferredSidebarWidth = clamp(
            finiteNonNegative(rawPreferredSidebarWidth),
            min: sidebarMin,
            max: sidebarMax
        )
        let preferredRightWidth = clamp(
            finiteNonNegative(rawPreferredRightWidth),
            min: rightMin,
            max: rightMax
        )

        guard rightPreferredVisible else {
            return calculateTwoPane(
                availableWidth: availableWidth,
                preferredSidebarWidth: preferredSidebarWidth,
                sidebarMin: sidebarMin,
                centerMin: centerMin,
                dividerWidth: dividerWidth
            )
        }

        let threePaneDividerWidth = dividerWidth * 2
        let threePaneMinimumWidth = sidebarMin + centerMin + rightMin + threePaneDividerWidth

        guard availableWidth >= threePaneMinimumWidth else {
            return calculateTwoPane(
                availableWidth: availableWidth,
                preferredSidebarWidth: preferredSidebarWidth,
                sidebarMin: sidebarMin,
                centerMin: centerMin,
                dividerWidth: dividerWidth
            )
        }

        let usableWidth = max(0, availableWidth - threePaneDividerWidth)
        let preferredSideTotal = preferredSidebarWidth + preferredRightWidth
        let preferredCenterWidth = usableWidth - preferredSideTotal

        guard preferredCenterWidth < centerMin else {
            return Result(
                sidebarWidth: preferredSidebarWidth,
                centerWidth: max(0, preferredCenterWidth),
                rightWidth: preferredRightWidth,
                rightVisible: true
            )
        }

        let sideBudget = max(0, usableWidth - centerMin)
        let overflow = max(0, preferredSideTotal - sideBudget)
        let sidebarShrinkCapacity = max(0, preferredSidebarWidth - sidebarMin)
        let rightShrinkCapacity = max(0, preferredRightWidth - rightMin)
        let totalShrinkCapacity = sidebarShrinkCapacity + rightShrinkCapacity

        let sidebarShrink: Double
        let rightShrink: Double
        if totalShrinkCapacity > 0 {
            sidebarShrink = min(sidebarShrinkCapacity, overflow * (sidebarShrinkCapacity / totalShrinkCapacity))
            rightShrink = min(rightShrinkCapacity, overflow * (rightShrinkCapacity / totalShrinkCapacity))
        } else {
            sidebarShrink = 0
            rightShrink = 0
        }

        var sidebarWidth = preferredSidebarWidth - sidebarShrink
        var rightWidth = preferredRightWidth - rightShrink

        let remainingOverflow = max(0, (sidebarWidth + rightWidth) - sideBudget)
        if remainingOverflow > 0 {
            if sidebarWidth > sidebarMin {
                let extra = min(sidebarWidth - sidebarMin, remainingOverflow)
                sidebarWidth -= extra
            }
            let stillRemaining = max(0, (sidebarWidth + rightWidth) - sideBudget)
            if stillRemaining > 0, rightWidth > rightMin {
                let extra = min(rightWidth - rightMin, stillRemaining)
                rightWidth -= extra
            }
        }

        sidebarWidth = max(sidebarMin, sidebarWidth)
        rightWidth = max(rightMin, rightWidth)
        let centerWidth = max(0, usableWidth - sidebarWidth - rightWidth)

        return Result(
            sidebarWidth: sidebarWidth,
            centerWidth: centerWidth,
            rightWidth: rightWidth,
            rightVisible: true
        )
    }

    private static func calculateTwoPane(
        availableWidth: Double,
        preferredSidebarWidth: Double,
        sidebarMin: Double,
        centerMin: Double,
        dividerWidth: Double
    ) -> Result {
        let usableWidth = max(0, availableWidth - dividerWidth)
        let sidebarWidth: Double

        if usableWidth >= preferredSidebarWidth + centerMin {
            sidebarWidth = preferredSidebarWidth
        } else if usableWidth >= sidebarMin + centerMin {
            sidebarWidth = max(sidebarMin, usableWidth - centerMin)
        } else if usableWidth <= 0 {
            sidebarWidth = 0
        } else {
            let denominator = sidebarMin + centerMin
            if denominator > 0 {
                sidebarWidth = usableWidth * (sidebarMin / denominator)
            } else {
                sidebarWidth = 0
            }
        }

        let clampedSidebarWidth = max(0, sidebarWidth)
        return Result(
            sidebarWidth: clampedSidebarWidth,
            centerWidth: max(0, usableWidth - clampedSidebarWidth),
            rightWidth: 0,
            rightVisible: false
        )
    }

    private static func finiteNonNegative(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private static func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        max(minValue, min(maxValue, value))
    }
}
