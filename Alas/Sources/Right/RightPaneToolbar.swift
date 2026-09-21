import SwiftUI

/// The right pane's context row. The selected rail tab already names the
/// panel, so this row carries per-tab context instead of a title.
struct RightPaneToolbar: View {
    let tab: RightPaneTab
    var branch: String = ""
    var totalAdd: Int = 0
    var totalDel: Int = 0
    var activeAgentCount: Int = 0
    var waitingAgentCount: Int = 0
    var runningScriptNames: [String] = []
    var scheduleCount: Int = 0
    var schedulesPaused: Bool = false
    var showIgnored: Bool = false
    var onToggleShowIgnored: () -> Void = {}
    var onSearch: () -> Void = {}
    let onOpenPreview: () -> Void
    let onNewRunScript: (RunScriptScope) -> Void

    @Environment(\.theme) private var theme
    @State private var previewHovered = false
    @State private var newScriptHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // Priorities, high to low: the accessories keep their intrinsic
            // width, the leading text then takes everything they leave, and the
            // drag filler only claims what is left over. Without them the stack
            // splits the row evenly and the branch name ellipsizes while the
            // rest of the row sits empty.
            leading
                .overlay { WindowDragHandle() }
                .layoutPriority(1)

            // The leading row carries its own drag handle, so this filler can
            // collapse to nothing when the branch name needs the whole row.
            WindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            trailing
                .layoutPriority(2)
            if tab == .run {
                runControls
                    .layoutPriority(2)
            }
            if RightPaneToolbarModel.showsOverflowMenu(for: tab) {
                overflowMenu
                    .layoutPriority(2)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        // Flush, not a `paneBand`: this row is the pane's chrome, and reads
        // as the counterpart to the center pane's toolbar. The floating
        // bands start below it.
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    /// Only the Changes tab names a branch, so only it gets the branch icon;
    /// the other tabs' leading text is a summary, not a ref.
    private var leading: some View {
        HStack(spacing: 4) {
            if tab == .changes {
                Icon(name: "branch", size: 10, color: theme.color("fg-muted"))
            }
            Text(RightPaneToolbarModel.leading(
                for: tab,
                branch: branch,
                activeAgentCount: activeAgentCount,
                waitingAgentCount: waitingAgentCount,
                runningScriptNames: runningScriptNames,
                scheduleCount: scheduleCount,
                schedulesPaused: schedulesPaused
            ))
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(theme.color("fg-muted"))
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch RightPaneToolbarModel.trailing(for: tab, totalAdd: totalAdd, totalDel: totalDel) {
        case .none:
            EmptyView()
        case .diffTotals(let add, let del):
            HStack(spacing: 6) {
                Text("+\(add)").foregroundColor(theme.color("add"))
                Text("−\(del)").foregroundColor(theme.color("del"))
            }
            .font(.system(size: 10.5, design: .monospaced))
        case .search:
            ToolbarBtn(icon: "search", tooltip: "Search files", action: onSearch)
        }
    }

    private var runControls: some View {
        HStack(spacing: 2) {
            Button(action: onOpenPreview) {
                HStack(spacing: 5) {
                    Icon(name: "globe", size: 11)
                    Text("Preview")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(theme.color(previewHovered ? "fg" : "fg-muted"))
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(previewHovered ? theme.color("bg-3") : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.toolbarControl)
            .onHover { previewHovered = $0 }
            .help("Open web preview")
            .accessibilityLabel("Open web preview")
            .accessibilityIdentifier("run-open-preview")

            Menu {
                Button("New Repo Script") { onNewRunScript(.repo) }
                Button("New Global Script") { onNewRunScript(.global) }
            } label: {
                Icon(name: "plus", size: 13, color: theme.color(newScriptHovered ? "fg" : "fg-muted"))
                    .toolbarControlSurface(isLit: newScriptHovered)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { newScriptHovered = $0 }
            .help("New run script")
            .accessibilityLabel("New run script")
            .accessibilityIdentifier("run-new-script")
        }
        .fixedSize()
    }

    private var overflowMenu: some View {
        Menu {
            Toggle("Show ignored or excluded files", isOn: Binding(
                get: { showIgnored },
                set: { _ in onToggleShowIgnored() }
            ))
        } label: {
            Icon(name: "menu", size: 12, color: theme.color("fg-faint"))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .help("More options")
    }
}
