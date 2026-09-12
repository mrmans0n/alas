import SwiftUI

/// The right pane while the selected worktree is in a transitional
/// operation state: `.creating`, `.deleting`, or `.createFailed`.
///
/// Does not touch `RightPaneStore`, so no per-worktree state is allocated
/// for a worktree that is not yet (or no longer) backed by a real path
/// on disk. The tab bar is rendered for layout consistency but is
/// `.disabled(true)` — all controls (including the hide-pane button) are
/// inert. Recovery actions for the failure states live on the sidebar row
/// context menu and the center pane.
///
/// The icon rail is the one exception: under the preview flag it is the
/// pane's only reveal affordance (the center pane suppresses its own
/// reveal button whenever the flag is on), so a rail tap must still be able
/// to expand a collapsed pane here — otherwise a pane collapsed before a
/// worktree entered a transitional state could never be reopened to show
/// its status. Tab identity has no real effect on `content` beyond which
/// skeleton variant `.creating` shows, so this reuses the same
/// `RightPaneRailModel.apply` transition `RightPaneView` uses.
struct RightPaneTransitionalView: View {
    enum Kind {
        case creating
        case deleting
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
            Group {
                if state.config.rightPaneRailEnabled {
                    HStack(spacing: 0) {
                        if !collapsed {
                            // Unlike the active pane, a transitional pane has
                            // no separate toolbar row — `content` is the only
                            // header-equivalent region, so it carries the
                            // drag handle the removed tab bar used to.
                            content
                                .windowDragHandle()
                        }
                        RightPaneRail(
                            activeTab: activeTab,
                            collapsed: collapsed,
                            changesCount: 0,
                            activeAgentCount: state.agentSidebarRollup(for: worktree).active.count,
                            showAgentTab: state.config.agentTabEnabled,
                            showRunTab: state.config.runTabEnabled,
                            onAction: { handle($0) }
                        )
                    }
                } else {
                    VStack(spacing: 0) {
                        RightPaneTabBar(
                            activeTab: $activeTab,
                            changesCount: 0,
                            totalAdd: 0,
                            totalDel: 0,
                            onHidePane: {},
                            showIgnored: state.config.files.showIgnored,
                            onToggleShowIgnored: {},
                            showAgentTab: state.config.agentTabEnabled,
                            showRunTab: state.config.runTabEnabled,
                            activeAgentCount: state.agentSidebarRollup(for: worktree).active.count
                        )
                        .disabled(true)

                        content
                    }
                }
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
        case .deleting:
            CompactStateLabel(
                systemIcon: "trash",
                text: "Deleting worktree…",
                tone: .neutral
            )
        case .createFailed:
            CompactStateLabel(
                systemIcon: "exclamationmark.triangle",
                text: "Create failed — \(worktree.branch)",
                tone: .warning
            )
        }
    }
}

// MARK: - Creating skeleton

struct RightPaneLoadingSkeletonView: View {
    let activeTab: RightPaneTab

    var body: some View {
        switch activeTab {
        case .changes:
            VStack(alignment: .leading, spacing: 0) {
                SkeletonSectionHeader(role: .workingTree, title: "Working tree")
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonRow(widthFraction: 0.75)
                    SkeletonRow(widthFraction: 0.55)
                    SkeletonRow(widthFraction: 0.65)
                    SkeletonRow(widthFraction: 0.4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                SkeletonSectionHeader(role: .commits, title: "Commits")
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonRow(widthFraction: 0.8)
                    SkeletonRow(widthFraction: 0.6)
                    SkeletonRow(widthFraction: 0.7)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .files, .agent, .run:
            VStack(alignment: .leading, spacing: 6) {
                SkeletonRow(widthFraction: 0.6,  leadingInset: 0)
                SkeletonRow(widthFraction: 0.5,  leadingInset: 16)
                SkeletonRow(widthFraction: 0.55, leadingInset: 16)
                SkeletonRow(widthFraction: 0.45, leadingInset: 32)
                SkeletonRow(widthFraction: 0.5,  leadingInset: 16)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Compact label (deleting / createFailed)

private struct CompactStateLabel: View {
    enum Tone {
        case neutral
        case warning
    }

    let systemIcon: String
    let text: String
    let tone: Tone

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemIcon)
                .font(.system(size: 22))
                .foregroundColor(iconColor)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    private var iconColor: Color {
        switch tone {
        case .neutral: return theme.color("fg-faint")
        case .warning: return theme.color("warning")
        }
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
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(theme.color("section-head-bg"))
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
