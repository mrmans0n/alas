import SwiftUI

struct SidebarHeaderView: View {
    let worktreeSortMode: AppConfig.WorktreeSortMode
    let onSetWorktreeSortMode: (AppConfig.WorktreeSortMode) -> Void
    let onSettings: () -> Void
    let onAddProject: () -> Void
    let onSearch: () -> Void
    let onHideSidebar: () -> Void
    var onNewWorkspace: (() -> Void)? = nil
    var attentionCount: Int = 0
    var attentionInboxOpen: Bool = false
    var onOpenAttentionInbox: () -> Void = {}
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var addMenuHovered = false

    static func showsAttentionBadge(count: Int) -> Bool { count > 0 }

    static func attentionAccessibilityLabel(count: Int) -> String {
        guard count > 0 else { return "Open attention inbox" }
        return "Open attention inbox, \(count) \(count == 1 ? "item" : "items")"
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            expandedHeader
            compactHeader
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .windowDragHandle()
    }

    private var expandedHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            TrafficLights()
            Spacer()
            HStack(alignment: .center, spacing: 2) {
                WorktreeSortMenu(
                    selection: worktreeSortMode,
                    onSelect: onSetWorktreeSortMode,
                    headerHovered: hovering
                )
                ToolbarBtn(icon: "search", tooltip: "Search", action: onSearch)
                AttentionToolbarButton(count: attentionCount, isOpen: attentionInboxOpen, action: onOpenAttentionInbox)
                if let onNewWorkspace {
                    Menu {
                        Button("Add repository...", systemImage: "folder.badge.plus", action: onAddProject)
                        Button("New workspace...", systemImage: "square.grid.2x2", action: onNewWorkspace)
                    } label: {
                        Icon(name: "folder-plus", size: 13, color: theme.color(addMenuHovered ? "fg" : "fg-muted"))
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                            .background(addMenuHovered ? theme.color("bg-3") : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .onHover { addMenuHovered = $0 }
                    .help("Add repository or workspace")
                    .accessibilityLabel("Add repository or workspace")
                } else {
                    ToolbarBtn(icon: "folder-plus", tooltip: "Add repository", action: onAddProject)
                }
                ToolbarBtn(icon: "gear", tooltip: "Settings", action: onSettings)
                ToolbarBtn(icon: "sidebar.left", tooltip: "Hide sidebar", action: onHideSidebar)
            }
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 8) {
            TrafficLights()
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ToolbarBtn(icon: "search", tooltip: "Search", action: onSearch)
                AttentionToolbarButton(count: attentionCount, isOpen: attentionInboxOpen, action: onOpenAttentionInbox)
                Menu {
                    Menu("Sort worktrees") {
                        ForEach(WorktreeSortPresentation.modes, id: \.self) { mode in
                            Toggle(WorktreeSortPresentation.title(for: mode), isOn: Binding(
                                get: { worktreeSortMode == mode },
                                set: { selected in if selected { onSetWorktreeSortMode(mode) } }
                            ))
                        }
                    }
                    Button("Add repository...", systemImage: "folder.badge.plus", action: onAddProject)
                    if let onNewWorkspace {
                        Button("New workspace...", systemImage: "square.grid.2x2", action: onNewWorkspace)
                    }
                    Divider()
                    Button("Settings", systemImage: "gear", action: onSettings)
                    Button("Hide sidebar", systemImage: "sidebar.left", action: onHideSidebar)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.color(addMenuHovered ? "fg" : "fg-muted"))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                        .background(addMenuHovered ? theme.color("bg-3") : .clear)
                        .clipShape(.rect(cornerRadius: 5))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { addMenuHovered = $0 }
                .help("More sidebar actions")
                .accessibilityLabel("More sidebar actions")
            }
        }
    }
}

private struct AttentionToolbarButton: View {
    let count: Int
    let isOpen: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.color(count > 0 ? "warn" : (hovering ? "fg" : "fg-muted")))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
                .background(theme.color("bg-3").opacity(hovering || isOpen ? 1 : 0))
                .clipShape(.rect(cornerRadius: 5))
                .overlay(alignment: .topTrailing) {
                    if SidebarHeaderView.showsAttentionBadge(count: count) {
                        Text(count > 999 ? "999+" : "\(count)")
                            .font(.system(size: 8, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(theme.color("bg-0"))
                            .padding(.horizontal, 3)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(theme.color("warn"), in: Capsule())
                            .fixedSize()
                            .offset(x: 3, y: -4)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(SidebarHeaderView.attentionAccessibilityLabel(count: count))
        .accessibilityLabel(SidebarHeaderView.attentionAccessibilityLabel(count: count))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

struct ToolbarBtn: View {
    let icon: String
    let tooltip: String
    let action: () -> Void
    @Environment(\.theme) var theme
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: 13, color: hovering ? theme.color("fg") : theme.color("fg-muted"))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
                .background(hovering ? theme.color("bg-3") : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }
}
