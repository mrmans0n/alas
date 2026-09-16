import SwiftUI

/// Row/section data behind the Files, Agent, and Run skeleton variants,
/// factored out of the views so the shapes are something tests can assert
/// on directly rather than only eyeballing the rendered pane.
enum RightPaneSkeletonLayout {
    struct FileRow: Equatable {
        let isDirectory: Bool
        let depth: Int
        let nameWidth: CGFloat
    }

    struct AgentSection: Equatable {
        let title: String
        let cardCount: Int
    }

    struct RunSection: Equatable {
        let title: String
        let rowWidths: [CGFloat]
    }

    /// A plausible small tree: a couple of nested directories, files at a
    /// couple of depths, back out to root. Depths never jump by more than
    /// one level from the row above, same as a real expanded tree.
    static let files: [FileRow] = [
        FileRow(isDirectory: true, depth: 0, nameWidth: 70),
        FileRow(isDirectory: true, depth: 1, nameWidth: 56),
        FileRow(isDirectory: false, depth: 2, nameWidth: 90),
        FileRow(isDirectory: false, depth: 2, nameWidth: 64),
        FileRow(isDirectory: false, depth: 1, nameWidth: 48),
        FileRow(isDirectory: true, depth: 0, nameWidth: 60),
        FileRow(isDirectory: false, depth: 1, nameWidth: 76),
        FileRow(isDirectory: false, depth: 0, nameWidth: 52),
    ]

    static let agentSections: [AgentSection] = [
        AgentSection(title: "Active", cardCount: 2),
        AgentSection(title: "History", cardCount: 1),
    ]

    static let runSections: [RunSection] = [
        RunSection(title: "Repo", rowWidths: [0.58, 0.72, 0.46]),
        RunSection(title: "Global", rowWidths: [0.64, 0.50]),
    ]
}

/// The right pane's per-tab loading skeleton: shown while a worktree's
/// `RightPaneState` snapshot hasn't loaded yet, and while a `.creating`
/// worktree has no backing state at all. Each tab gets a shape resembling
/// its real content so the pane doesn't flash a generic placeholder before
/// snapping into its actual layout.
struct RightPaneLoadingSkeletonView: View {
    let activeTab: RightPaneTab

    var body: some View {
        switch activeTab {
        case .changes:
            ChangesSkeletonView()
        case .files:
            FilesSkeletonView()
        case .agent:
            AgentSkeletonView()
        case .run:
            RunSkeletonView()
        }
    }
}

// MARK: - Changes skeleton

private struct ChangesSkeletonView: View {
    var body: some View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading changes")
    }
}

// MARK: - Files skeleton

private struct FilesSkeletonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(RightPaneSkeletonLayout.files.enumerated()), id: \.offset) { _, row in
                FileSkeletonRow(row: row)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading files")
    }
}

private struct FileSkeletonRow: View {
    let row: RightPaneSkeletonLayout.FileRow
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: row.isDirectory ? 3 : 4)
                .fill(theme.color("fg-faint").opacity(0.3))
                .frame(width: row.isDirectory ? 13 : 14, height: row.isDirectory ? 11 : 14)
            Capsule()
                .fill(theme.color("fg-faint").opacity(0.3))
                .frame(width: row.nameWidth, height: 8)
            Spacer(minLength: 0)
        }
        // Same indentation math the real tree rows use, so the skeleton's
        // nesting doesn't shift once the real tree loads in.
        .padding(.leading, FileTreeListView.rowLeadingPadding(depth: row.depth))
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Agent skeleton

private struct AgentSkeletonView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(RightPaneSkeletonLayout.agentSections, id: \.title) { section in
                    AgentSkeletonSectionHeader(title: section.title)
                    ForEach(0..<section.cardCount, id: \.self) { _ in
                        AgentSkeletonCard()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading agent sessions")
    }
}

private struct AgentSkeletonSectionHeader: View {
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(theme.color("fg-muted"))
            Capsule()
                .fill(theme.color("fg-faint").opacity(0.3))
                .frame(width: 16, height: 12)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }
}

private struct AgentSkeletonCard: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.color("fg-faint").opacity(0.16))
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(theme.color("fg-faint").opacity(0.3)).frame(width: 120, height: 9)
                Capsule().fill(theme.color("fg-faint").opacity(0.3)).frame(width: 70, height: 7)
            }
            Spacer(minLength: 0)
            Capsule()
                .fill(theme.color("fg-faint").opacity(0.3))
                .frame(width: 40, height: 14)
        }
        .padding(10)
        .background(theme.color("fg-faint").opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(theme.color("line").opacity(0.5), lineWidth: 0.75)
        )
    }
}

// MARK: - Run skeleton

private struct RunSkeletonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RightPaneSkeletonLayout.runSections, id: \.title) { section in
                RunSkeletonSectionHeader(title: section.title)
                ForEach(Array(section.rowWidths.enumerated()), id: \.offset) { _, width in
                    RunSkeletonRow(nameWidthFraction: width)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, PaneBandLayout.outerVertical)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading run scripts")
    }
}

private struct RunSkeletonSectionHeader: View {
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
            Capsule()
                .fill(theme.color("fg-faint").opacity(0.3))
                .frame(width: 16, height: 12)
            Spacer(minLength: 8)
        }
        .paneBand(fill: theme.color("section-head-bg"))
    }
}

private struct RunSkeletonRow: View {
    let nameWidthFraction: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(theme.color("fg-faint").opacity(0.3))
                .frame(width: 8, height: 8)
            Capsule()
                .fill(theme.color("fg-faint").opacity(0.3))
                .frame(width: 140 * nameWidthFraction, height: 8)
            Spacer(minLength: 8)
            Capsule()
                .fill(theme.color("fg-faint").opacity(0.3))
                .frame(width: 36, height: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Skeleton primitives (Changes)

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
