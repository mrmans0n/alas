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
struct RightPaneTransitionalView: View {
    enum Kind {
        case creating
        case deleting
        case createFailed
    }

    @Bindable var state: AppState
    let worktree: Worktree
    let kind: Kind

    @State private var activeTab: RightPaneTab = .changes

    var body: some View {
        let override = state.config.sidebarChromeOverride(forThemeId: state.themeStore.current.id)
        ZStack {
            SidebarMaterialBackground(
                choice: state.config.sidebarMaterial,
                backgroundOpacity: override.backgroundOpacity
            )
            VStack(spacing: 0) {
                RightPaneTabBar(
                    activeTab: $activeTab,
                    changesCount: 0,
                    totalAdd: 0,
                    totalDel: 0,
                    onHidePane: {},
                    showIgnored: state.config.files.showIgnored,
                    onToggleShowIgnored: {}
                )
                .disabled(true)

                content
            }
            .sidebarChromeTheme(textContrast: override.textContrast)
        }
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

        case .files:
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
