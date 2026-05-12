import SwiftUI
import AppKit

struct TerminalTabView: View {
    @Bindable var state: AppState
    let worktreeId: String
    let tabId: TabID

    @Environment(\.theme) var theme

    var body: some View {
        Group {
            if let tab = currentTab() {
                PaneNodeView(
                    state: state,
                    worktreeId: worktreeId,
                    tabId: tabId,
                    node: tab.root,
                    focusedLeafId: tab.focusedLeafId
                )
            } else {
                TerminalRecoverPlaceholder(state: state, worktreeId: worktreeId, tabId: tabId)
            }
        }
        .coordinateSpace(name: tabCoordinateSpace)
        .onPreferenceChange(LeafFramesKey.self) { frames in
            state.terminalLeafFrames[tabId] = frames
        }
        .task(id: tabId) {
            _ = try? state.restoreTerminalTabIfNeeded(worktreeId: worktreeId, tabId: tabId)
        }
        .background(theme.color("bg-0"))
    }

    private var tabCoordinateSpace: String { "alas-tab-\(tabId)" }

    private func currentTab() -> TerminalTabState? {
        state.tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }).flatMap {
            if case .terminal(let s) = $0 { return s } else { return nil }
        }
    }
}

private struct PaneNodeView: View {
    @Bindable var state: AppState
    let worktreeId: String
    let tabId: TabID
    let node: PaneNode
    let focusedLeafId: String

    var body: some View {
        switch node {
        case .leaf(let leaf):
            PaneLeafView(
                state: state,
                worktreeId: worktreeId,
                tabId: tabId,
                leaf: leaf,
                isFocused: leaf.id == focusedLeafId
            )
        case .split(let split):
            SplitContainer(
                state: state,
                worktreeId: worktreeId,
                tabId: tabId,
                split: split,
                focusedLeafId: focusedLeafId
            )
        }
    }
}

private struct PaneLeafView: View {
    @Bindable var state: AppState
    let worktreeId: String
    let tabId: TabID
    let leaf: PaneLeaf
    let isFocused: Bool

    @Environment(\.theme) var theme

    var body: some View {
        Group {
            if let session = state.terminal.registry.session(for: leaf.sessionId) {
                GhosttyHost(session: session, isFocused: isFocused)
                    .id(leaf.sessionId)
                    .onAppear { wireCwdHandler(session: session) }
            } else {
                Color.clear
            }
        }
        .overlay(
            Rectangle()
                .strokeBorder(isFocused ? theme.color("accent") : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            _ = state.tabs.setFocusedLeaf(worktreeId: worktreeId, tabId: tabId, leafId: leaf.id)
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: LeafFramesKey.self,
                    value: [leaf.id: geo.frame(in: .named("alas-tab-\(tabId)"))]
                )
            }
        )
    }

    private func wireCwdHandler(session: TerminalSession) {
        session.surface.cwdHandler = { [worktreeId, tabId, leafId = leaf.id] url in
            _ = state.tabs.setLeafCwd(
                worktreeId: worktreeId, tabId: tabId, leafId: leafId, cwd: url.path
            )
        }
    }
}

private struct SplitContainer: View {
    @Bindable var state: AppState
    let worktreeId: String
    let tabId: TabID
    let split: PaneSplit
    let focusedLeafId: String

    @Environment(\.theme) var theme

    private let dividerThickness: CGFloat = 4
    @State private var isDividerHovering = false

    var body: some View {
        GeometryReader { geo in
            let total: CGFloat = split.axis == .vertical ? geo.size.width : geo.size.height
            let usable = max(0, total - dividerThickness)
            let firstSize = max(20, usable * split.fraction)
            let secondSize = max(20, usable - firstSize)
            let totalForFraction = usable
            content(firstSize: firstSize, secondSize: secondSize, totalForFraction: totalForFraction)
        }
    }

    @ViewBuilder
    private func content(firstSize: CGFloat, secondSize: CGFloat, totalForFraction: CGFloat) -> some View {
        if split.axis == .vertical {
            HStack(spacing: 0) {
                PaneNodeView(state: state, worktreeId: worktreeId, tabId: tabId,
                             node: split.children[0], focusedLeafId: focusedLeafId)
                    .frame(width: firstSize)
                    .clipped()
                dividerView(totalForFraction: totalForFraction)
                PaneNodeView(state: state, worktreeId: worktreeId, tabId: tabId,
                             node: split.children[1], focusedLeafId: focusedLeafId)
                    .frame(width: secondSize)
                    .clipped()
            }
        } else {
            VStack(spacing: 0) {
                PaneNodeView(state: state, worktreeId: worktreeId, tabId: tabId,
                             node: split.children[0], focusedLeafId: focusedLeafId)
                    .frame(height: firstSize)
                    .clipped()
                dividerView(totalForFraction: totalForFraction)
                PaneNodeView(state: state, worktreeId: worktreeId, tabId: tabId,
                             node: split.children[1], focusedLeafId: focusedLeafId)
                    .frame(height: secondSize)
                    .clipped()
            }
        }
    }

    private func dividerView(totalForFraction: CGFloat) -> some View {
        let isVertical = split.axis == .vertical
        return Rectangle()
            .fill(theme.color("bg-3"))
            .frame(
                width: isVertical ? dividerThickness : nil,
                height: isVertical ? nil : dividerThickness
            )
            .contentShape(Rectangle())
            .onHover { nowHovering in
                guard nowHovering != isDividerHovering else { return }
                isDividerHovering = nowHovering
                if nowHovering {
                    if isVertical { NSCursor.resizeLeftRight.push() }
                    else          { NSCursor.resizeUpDown.push() }
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta: CGFloat = isVertical ? value.translation.width : value.translation.height
                        let initialFirst = split.fraction * totalForFraction
                        let newFraction = (initialFirst + delta) / totalForFraction
                        _ = state.tabs.setSplitFraction(
                            worktreeId: worktreeId, tabId: tabId,
                            splitId: split.id, fraction: newFraction
                        )
                    }
            )
    }
}

private struct LeafFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}

private struct TerminalRecoverPlaceholder: View {
    @Bindable var state: AppState
    let worktreeId: String
    let tabId: TabID
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 12) {
            Text("Terminal closed")
                .font(.system(size: 14))
                .foregroundColor(theme.color("fg-muted"))
            AlasButton(title: "Open new terminal", style: .primary) {
                Task { _ = try? state.restoreTerminalTabIfNeeded(worktreeId: worktreeId, tabId: tabId) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-0"))
    }
}
