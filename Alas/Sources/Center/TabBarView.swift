import SwiftUI

struct TabBarView: View {
    let tabs: [Tab]
    let activeId: TabID?
    let harnessLookup: (TabID) -> (agent: AgentKind, state: ActivityState)?
    let dirtyLookup: (TabID) -> Bool
    let onActivate: (TabID) -> Void
    let onClose: (TabID) -> Void
    let onCloseOthers: (TabID) -> Void
    let onCloseAll: () -> Void
    let onCloseToLeft: (TabID) -> Void
    let onCloseToRight: (TabID) -> Void
    let onCopyPath: (TabID) -> Void
    let onCopyRelativePath: (TabID) -> Void
    let onRenameTerminal: (TabID) -> Void
    let onNewTerminal: () -> Void
    let onMove: (TabID, TabID) -> Void
    @Environment(\.theme) var theme
    @State private var draggedTabId: TabID?
    @State private var tabFrames: [TabID: CGRect] = [:]

    private static let dragCoordinateSpace = "alas-tab-bar-drag"

    private var isTerminalActive: Bool {
        guard let activeId, let active = tabs.first(where: { $0.id == activeId }) else { return false }
        if case .terminal = active { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { idx, tab in
                TabButton(
                    tab: tab,
                    active: tab.id == activeId,
                    showClose: tabs.count > 1,
                    harnessInfo: harnessLookup(tab.id),
                    dirty: dirtyLookup(tab.id),
                    onActivate: { onActivate(tab.id) },
                    onClose: { onClose(tab.id) }
                )
                .opacity(draggedTabId == tab.id ? 0.75 : 1)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: TabButtonFramePreferenceKey.self,
                            value: [tab.id: proxy.frame(in: .named(Self.dragCoordinateSpace))]
                        )
                    }
                )
                .highPriorityGesture(tabDragGesture(for: tab.id))
                .contextMenu {
                    if case .terminal = tab {
                        Button("Rename…") { onRenameTerminal(tab.id) }
                        Divider()
                    }
                    Button("Close") { onClose(tab.id) }
                    Button("Close Other Tabs") { onCloseOthers(tab.id) }
                        .disabled(tabs.count <= 1)
                    Button("Close All Tabs") { onCloseAll() }
                    Button("Close Tabs to the Left") { onCloseToLeft(tab.id) }
                        .disabled(idx == 0)
                    Button("Close Tabs to the Right") { onCloseToRight(tab.id) }
                        .disabled(idx == tabs.count - 1)
                    Divider()
                    if tab.relativeFilePath != nil {
                        Button("Copy Path") { onCopyPath(tab.id) }
                        Button("Copy Relative Path") { onCopyRelativePath(tab.id) }
                    }
                }
            }
            Spacer()
            if isTerminalActive {
                ToolbarIconButton(iconName: "split", tooltip: "Split Right (⌘D)") {
                    NotificationCenter.default.post(name: .alasSplitRight, object: nil)
                }
                ToolbarIconButton(iconName: "split-down", tooltip: "Split Down (⇧⌘D)") {
                    NotificationCenter.default.post(name: .alasSplitDown, object: nil)
                }
            }
            Button(action: onNewTerminal) {
                Icon(name: "plus", size: 13)
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .help("New terminal")
            .padding(.horizontal, 8)
        }
        .coordinateSpace(name: Self.dragCoordinateSpace)
        .frame(height: 34)
        .background {
            theme.color("bg-2")
            TabDragWindowShield()
        }
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .onPreferenceChange(TabButtonFramePreferenceKey.self) { frames in
            tabFrames = frames
        }
    }

    private func tabDragGesture(for tabId: TabID) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.dragCoordinateSpace))
            .onChanged { value in
                if draggedTabId == nil {
                    draggedTabId = tabId
                }
                guard draggedTabId == tabId,
                      let targetId = tabFrames.first(where: { $0.value.contains(value.location) })?.key,
                      targetId != tabId else { return }
                onMove(tabId, targetId)
            }
            .onEnded { _ in
                draggedTabId = nil
            }
    }
}

private struct TabButtonFramePreferenceKey: PreferenceKey {
    static var defaultValue: [TabID: CGRect] = [:]

    static func reduce(value: inout [TabID: CGRect], nextValue: () -> [TabID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TabButton: View {
    let tab: Tab
    let active: Bool
    let showClose: Bool
    let harnessInfo: (agent: AgentKind, state: ActivityState)?
    let dirty: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    @Environment(\.theme) var theme
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            Icon(name: tab.iconName, size: 11,
                 color: active ? theme.color("accent") : theme.color("fg-faint"))
            Text(tab.title)
                .font(.system(size: 11.5))
                .foregroundColor(active ? theme.color("fg") : theme.color("fg-dim"))
                .lineLimit(1)
            if case .editor(let state) = tab, state.isExternal {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            if let info = harnessInfo {
                Circle().fill(stateColor(info.state)).frame(width: 6, height: 6)
                    .opacity(info.state == .busy ? 0.85 : 1)
            }
            if showClose {
                Button(action: onClose) {
                    ZStack {
                        if dirty && !hoveringClose {
                            Circle()
                                .fill(theme.color("fg"))
                                .frame(width: 7, height: 7)
                        } else {
                            Icon(name: "x", size: 9,
                                 color: hoveringClose ? theme.color("fg") : theme.color("fg-faint"))
                                .background(hoveringClose ? theme.color("bg-4") : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .onHover { hoveringClose = $0 }
                .help(dirty ? "Unsaved changes — click to close" : "Close")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(active ? theme.color("bg-1") : .clear)
        .overlay(
            Rectangle()
                .fill(active ? theme.color("accent") : .clear)
                .frame(height: 2),
            alignment: .bottom
        )
        .onTapGesture(perform: onActivate)
    }

    private func stateColor(_ s: ActivityState) -> Color {
        switch s {
        case .busy:          return theme.color("add")
        case .awaitingInput: return theme.color("mod")
        case .idle:          return theme.color("fg-faint")
        }
    }
}

private struct ToolbarIconButton: View {
    let iconName: String
    let tooltip: String
    let action: () -> Void
    @Environment(\.theme) var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Icon(name: iconName, size: 13,
                 color: hovering ? theme.color("fg") : theme.color("fg-faint"))
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
    }
}
