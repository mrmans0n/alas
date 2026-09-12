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
    var showIgnored: Bool = false
    var onToggleShowIgnored: () -> Void = {}
    var onSearch: () -> Void = {}

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            leading

            Spacer(minLength: 6)
            trailing
            if RightPaneToolbarModel.showsOverflowMenu(for: tab) {
                overflowMenu
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .windowDragHandle()
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
                runningScriptNames: runningScriptNames
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
