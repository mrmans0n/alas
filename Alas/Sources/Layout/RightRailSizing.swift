import Foundation

/// Wraps `ThreePaneSizing` for the icon rail presentation, where a 36pt rail
/// stays on screen after the pane body collapses.
///
/// When the body is expanded the rail is drawn inside the right pane's own
/// width, so nothing needs reserving. When the body is hidden — whether the
/// user collapsed it or the window was too narrow for `ThreePaneSizing` to
/// keep it — the rail becomes a separate strip, and the remaining panes have
/// to negotiate the width that is left. `ThreePaneSizing` is not modified;
/// it is simply asked a second time with a smaller budget.
enum RightRailSizing {
    struct Result: Equatable {
        var sizing: ThreePaneSizing.Result
        /// Width of the standalone rail strip. Zero when no strip is drawn,
        /// either because the flag is off or because the body is expanded.
        var railWidth: Double
    }

    static func calculate(
        availableWidth: Double,
        preferredSidebarWidth: Double,
        preferredRightWidth: Double,
        sidebarPreferredVisible: Bool,
        rightPreferredVisible: Bool,
        railWidth: Double?,
        configuration: ThreePaneSizing.Configuration
    ) -> Result {
        let sizing = ThreePaneSizing.calculate(
            availableWidth: availableWidth,
            preferredSidebarWidth: preferredSidebarWidth,
            preferredRightWidth: preferredRightWidth,
            sidebarPreferredVisible: sidebarPreferredVisible,
            rightPreferredVisible: rightPreferredVisible,
            configuration: configuration
        )

        guard let railWidth, railWidth > 0, !sizing.rightVisible else {
            return Result(sizing: sizing, railWidth: 0)
        }

        let reduced = ThreePaneSizing.calculate(
            availableWidth: max(0, availableWidth - railWidth),
            preferredSidebarWidth: preferredSidebarWidth,
            preferredRightWidth: preferredRightWidth,
            sidebarPreferredVisible: sidebarPreferredVisible,
            rightPreferredVisible: false,
            configuration: configuration
        )
        return Result(sizing: reduced, railWidth: railWidth)
    }
}
