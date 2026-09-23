import SwiftUI

/// The right pane while the selected worktree is in a transitional
/// operation state: `.creating` or `.createFailed`.
///
/// A worktree being *deleted* resolves to `.empty` instead — the pane
/// unmounts so the removal takes its rail with it.
///
/// Does not touch `RightPaneStore`, so no per-worktree state is allocated
/// for a worktree that is not yet (or no longer) backed by a real path
/// on disk. Recovery actions for the failure states live on the sidebar row
/// context menu and the center pane.
///
/// The permanent icon rail is the pane's only reveal affordance, so a rail
/// tap must still be able to expand a collapsed pane here — otherwise a pane
/// collapsed before a worktree entered a transitional state could never be
/// reopened to show its status. Tab identity affects only the `.creating`
/// skeleton variant, so this reuses the same
/// `RightPaneRailModel.apply` transition `RightPaneView` uses.
struct RightPaneTransitionalView: View {
    enum Kind {
        case creating
        case createFailed
    }

    @Bindable var state: AppState
    let worktree: Worktree
    let kind: Kind
    var collapsed: Bool = false

    @State private var activeTab: RightPaneTab = .changes

    var body: some View {
        let override = state.config.sidebarChromeOverride(forThemeId: state.themeStore.current.id)
        ZStack {
            SidebarMaterialBackground(
                choice: state.config.sidebarMaterial,
                backgroundOpacity: override.backgroundOpacity
            )
            HStack(spacing: 0) {
                if !collapsed {
                    // Transitional content has no actions, so its entire
                    // visible surface can move the nonmovable main window.
                    ZStack {
                        WindowDragHandle()
                        content
                            .allowsHitTesting(false)
                    }
                }
                RightPaneRail(
                    activeTab: activeTab,
                    collapsed: collapsed,
                    changesCount: 0,
                    activeAgentCount: state.agentSidebarRollup(for: worktree).active.count,
                    onAction: { handle($0) }
                )
            }
            .sidebarChromeTheme(textContrast: override.textContrast)
            .onReceive(NotificationCenter.default.publisher(for: .alasSelectRightPaneTab)) { notification in
                handleTabShortcut(notification)
            }
        }
    }

    /// Shared by the rail's own taps and by the tab shortcuts, so both move
    /// this pane the same way. There is no `RightPaneState` for a transitional
    /// worktree — `activeTab` is local — but the pane can still be opened and
    /// closed, and `.creating` varies its skeleton by tab.
    private func handle(_ action: RightPaneRailAction) {
        let outcome = RightPaneRailModel.apply(
            action,
            currentTab: activeTab,
            currentVisible: state.config.rightPaneVisible
        )
        activeTab = outcome.tab
        if state.config.rightPaneVisible != outcome.visible {
            state.config.rightPaneVisible = outcome.visible
            state.saveConfig()
        }
    }

    private func handleTabShortcut(_ notification: Notification) {
        guard let raw = notification.object as? String,
              let tab = RightPaneTab(rawValue: raw),
              state.acceptsRightPaneTabShortcut(tab)
        else { return }
        handle(RightPaneRailAction.resolve(tapped: tab, active: activeTab, collapsed: collapsed))
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .creating:
            RightPaneLoadingSkeletonView(activeTab: activeTab)
        case .createFailed:
            CompactStateLabel(
                systemIcon: "exclamationmark.triangle",
                text: "Create failed — \(worktree.branch)"
            )
        }
    }
}

// MARK: - Compact label (createFailed)

private struct CompactStateLabel: View {
    let systemIcon: String
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemIcon)
                .font(.system(size: 22))
                .foregroundColor(theme.color("warning"))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }
}

// MARK: - Skeleton primitives

private struct SkeletonSectionHeader: View {
    let role: SectionHeaderRole
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            SectionHeaderIcon(
                role: role,
                size: 10,
                color: theme.color("fg-faint")
            )
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
            Spacer(minLength: 8)
        }
        .paneBand(fill: theme.color("section-head-bg"))
    }
}

private struct SkeletonRow: View {
    let widthFraction: CGFloat
    var leadingInset: CGFloat = 0

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if leadingInset > 0 {
                Color.clear.frame(width: leadingInset)
            }
            GeometryReader { geo in
                Capsule()
                    .fill(theme.color("fg-faint").opacity(0.3))
                    .frame(width: max(20, geo.size.width * widthFraction), height: 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 8)
        }
    }
}
