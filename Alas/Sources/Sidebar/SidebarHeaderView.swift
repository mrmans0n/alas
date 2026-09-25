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
    var showsAttentionInbox = true
    @Binding var attentionInboxOpen: Bool
    var attentionAggregation: AttentionAggregation = AttentionAggregation(items: [], history: [], unresolvedCount: 0, unresolvedCountByProject: [:])
    var peerAttentionRows: [RemoteSessionSummary] = []
    var attentionLoadError: String? = nil
    var attentionWriteError: String? = nil
    var attentionNavigationErrors: [UUID: String] = [:]
    var onDismissAttentionItem: (AttentionItem) -> Void = { _ in }
    var onOpenAttentionItem: (AttentionItem) async -> Void = { _ in }
    var onOpenPeerSession: (RemoteSessionSummary) -> Void = { _ in }
    init(worktreeSortMode: AppConfig.WorktreeSortMode,
         onSetWorktreeSortMode: @escaping (AppConfig.WorktreeSortMode) -> Void,
         onSettings: @escaping () -> Void,
         onAddProject: @escaping () -> Void,
         onSearch: @escaping () -> Void,
         onHideSidebar: @escaping () -> Void,
         onNewWorkspace: (() -> Void)? = nil,
         attentionCount: Int = 0,
         showsAttentionInbox: Bool = true,
         attentionInboxOpen: Binding<Bool> = .constant(false),
         attentionAggregation: AttentionAggregation = AttentionAggregation(items: [], history: [], unresolvedCount: 0, unresolvedCountByProject: [:]),
         peerAttentionRows: [RemoteSessionSummary] = [],
         attentionLoadError: String? = nil,
         attentionWriteError: String? = nil,
         attentionNavigationErrors: [UUID: String] = [:],
         onDismissAttentionItem: @escaping (AttentionItem) -> Void = { _ in },
         onOpenAttentionItem: @escaping (AttentionItem) async -> Void = { _ in },
         onOpenPeerSession: @escaping (RemoteSessionSummary) -> Void = { _ in }) {
        self.worktreeSortMode = worktreeSortMode
        self.onSetWorktreeSortMode = onSetWorktreeSortMode
        self.onSettings = onSettings
        self.onAddProject = onAddProject
        self.onSearch = onSearch
        self.onHideSidebar = onHideSidebar
        self.onNewWorkspace = onNewWorkspace
        self.attentionCount = attentionCount
        self.showsAttentionInbox = showsAttentionInbox
        self._attentionInboxOpen = attentionInboxOpen
        self.attentionAggregation = attentionAggregation
        self.peerAttentionRows = peerAttentionRows
        self.attentionLoadError = attentionLoadError
        self.attentionWriteError = attentionWriteError
        self.attentionNavigationErrors = attentionNavigationErrors
        self.onDismissAttentionItem = onDismissAttentionItem
        self.onOpenAttentionItem = onOpenAttentionItem
        self.onOpenPeerSession = onOpenPeerSession
    }
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var addMenuHovered = false
    /// `Menu` does not expose press state to its label, so both menu-backed
    /// header controls track it with a simultaneous gesture, as the tab bar does.
    @GestureState private var addMenuPressed = false
    @GestureState private var compactMenuPressed = false

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
        .padding(.horizontal, 11)
        .frame(height: 38)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func attentionToolbarButton(metrics: ToolbarControlMetrics = .standard) -> some View {
        AttentionToolbarButton(count: attentionCount, isOpen: $attentionInboxOpen, metrics: metrics) {
            AttentionInboxView(
                aggregation: attentionAggregation,
                peerRows: peerAttentionRows,
                loadError: attentionLoadError,
                writeError: attentionWriteError,
                navigationErrors: attentionNavigationErrors,
                onDismiss: onDismissAttentionItem,
                onOpen: onOpenAttentionItem,
                onOpenPeer: onOpenPeerSession
            )
        }
    }

    private var expandedHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            TrafficLights()
            WindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(alignment: .center, spacing: 1) {
                WorktreeSortMenu(
                    selection: worktreeSortMode,
                    onSelect: onSetWorktreeSortMode,
                    headerHovered: hovering
                )
                ToolbarBtn(icon: "search", tooltip: "Search",
                           metrics: .sidebarHeader, action: onSearch)
                if showsAttentionInbox {
                    attentionToolbarButton(metrics: .sidebarHeader)
                }
                if let onNewWorkspace {
                    Menu {
                        Button("Add repository...", systemImage: "folder.badge.plus", action: onAddProject)
                        Button("New workspace...", systemImage: "square.grid.2x2", action: onNewWorkspace)
                    } label: {
                        Icon(name: "folder-plus", size: 13, color: theme.color(addMenuHovered ? "fg" : "fg-muted"))
                            .toolbarControlSurface(
                                isLit: ToolbarMenuControlPresentation.isLit(
                                    hovering: addMenuHovered,
                                    isPressed: addMenuPressed
                                ),
                                metrics: .sidebarHeader
                            )
                            .toolbarMenuControlPressFeedback(isPressed: addMenuPressed)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .updating($addMenuPressed) { _, state, _ in state = true }
                    )
                    .onHover { addMenuHovered = $0 }
                    .help("Add repository or workspace")
                    .accessibilityLabel("Add repository or workspace")
                } else {
                    ToolbarBtn(icon: "folder-plus", tooltip: "Add repository",
                               metrics: .sidebarHeader, action: onAddProject)
                }
                ToolbarBtn(icon: "gear", tooltip: "Settings",
                           metrics: .sidebarHeader, action: onSettings)
                ToolbarBtn(icon: "sidebar.left", tooltip: "Hide sidebar",
                           metrics: .sidebarHeader, action: onHideSidebar)
            }
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 8) {
            TrafficLights()
            WindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 2) {
                ToolbarBtn(icon: "search", tooltip: "Search", action: onSearch)
                if showsAttentionInbox {
                    attentionToolbarButton()
                }
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
                        // Compact keeps `.standard` metrics: this row's controls
                        // are sized for narrow sidebars, not E1's header band.
                        .toolbarControlSurface(
                            isLit: ToolbarMenuControlPresentation.isLit(
                                hovering: addMenuHovered,
                                isPressed: compactMenuPressed
                            )
                        )
                        .toolbarMenuControlPressFeedback(isPressed: compactMenuPressed)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .updating($compactMenuPressed) { _, state, _ in state = true }
                )
                .onHover { addMenuHovered = $0 }
                .help("More sidebar actions")
                .accessibilityLabel("More sidebar actions")
            }
        }
    }
}

private struct AttentionToolbarButton<Content: View>: View {
    let count: Int
    @Binding var isOpen: Bool
    var metrics: ToolbarControlMetrics = .standard
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "tray")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.color(hovering || isOpen ? "fg" : "fg-muted"))
                .frame(width: metrics.width, height: metrics.height)
                .contentShape(Rectangle())
                .background(theme.color("bg-3").opacity(hovering || isOpen ? 1 : 0))
                .clipShape(.rect(cornerRadius: metrics.cornerRadius))
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
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            content()
        }
    }
}

struct ToolbarBtn: View {
    let icon: String
    let tooltip: String
    /// Renders the button as switched on: accent icon over the same filled
    /// surface hover uses. Toolbar toggles adopt it so their state reads
    /// without needing a second control next to them.
    var isActive: Bool = false
    var metrics: ToolbarControlMetrics = .standard
    let action: () -> Void
    @Environment(\.theme) var theme
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: 13, color: iconColor)
                .toolbarControlSurface(isLit: hovering || isActive, metrics: metrics)
        }
        .buttonStyle(.toolbarControl)
        .onHover { hovering = $0 }
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var iconColor: Color {
        if isActive { return theme.color("accent") }
        return hovering ? theme.color("fg") : theme.color("fg-muted")
    }
}
