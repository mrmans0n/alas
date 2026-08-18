import SwiftUI
import AppKit

struct TerminalTabView: View {
    @Bindable var state: AppState
    let worktreeId: String
    let tabId: TabID
    var allowsPaneFocus: Bool = true

    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 0) {
            if let tab = currentTab() {
                AgentHookInstallNudgeBanner(appState: state, terminalTab: tab)
                PaneNodeView(
                    state: state,
                    worktreeId: worktreeId,
                    tabId: tabId,
                    node: tab.root,
                    focusedLeafId: tab.focusedLeafId,
                    allowsPaneFocus: allowsPaneFocus,
                    inSplit: false
                )
            } else {
                TerminalRecoverPlaceholder(state: state, worktreeId: worktreeId, tabId: tabId)
            }
        }
        .coordinateSpace(.named(tabCoordinateSpace))
        .onPreferenceChange(LeafFramesKey.self) { frames in
            state.terminalLeafFrames[tabId] = frames
        }
        .task(id: tabId) {
            _ = try? await state.restoreTerminalTabIfNeededAsync(worktreeId: worktreeId, tabId: tabId)
            state.completeStartupRecovery()
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
    let allowsPaneFocus: Bool
    let inSplit: Bool

    var body: some View {
        switch node {
        case .leaf(let leaf):
            PaneLeafView(
                state: state,
                worktreeId: worktreeId,
                tabId: tabId,
                leaf: leaf,
                isFocused: leaf.id == focusedLeafId && allowsPaneFocus,
                showFocusBorder: inSplit
            )
        case .split(let split):
            SplitContainer(
                state: state,
                worktreeId: worktreeId,
                tabId: tabId,
                split: split,
                focusedLeafId: focusedLeafId,
                allowsPaneFocus: allowsPaneFocus
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
    let showFocusBorder: Bool

    @Environment(\.theme) var theme

    var body: some View {
        Group {
            // Look up by leaf.id (the stable identity used as the registry
            // key and zmx session name). leaf.sessionId is mirrored to id
            // for new state and normalized on decode for legacy state, so
            // both happen to be equal — but `id` is the canonical identity.
            if let session = state.terminal.registry.session(for: leaf.id) {
                GhosttyHost(session: session, isFocused: isFocused)
                    .onAppear {
                        wireCwdHandler(session: session)
                        wireOpenURLHandler(session: session)
                        wireTitleHandler(session: session, leafId: leaf.id)
                    }
            } else {
                Color.clear
            }
        }
        .overlay(
            Rectangle()
                .strokeBorder(
                    showFocusBorder && isFocused ? theme.color("accent") : Color.clear,
                    lineWidth: 1
                )
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

    private func wireOpenURLHandler(session: TerminalSession) {
        session.surface.openURLHandler = { [weak state, sessionId = session.id] rawURL in
            guard let state else { return false }
            return state.routeTerminalOpenURL(rawURL: rawURL, sessionId: sessionId)
        }
    }

    private func wireTitleHandler(session: TerminalSession, leafId: String) {
        session.surface.titleHandler = { [weak state] title in
            guard let state, !title.isEmpty else { return }
            guard state.config.terminal.syncTabTitleWithTerminalTitle else { return }
            state.tabs.setTerminalRuntimeTitle(leafId: leafId, title: title)
        }
    }
}

private struct SplitContainer: View {
    @Bindable var state: AppState
    let worktreeId: String
    let tabId: TabID
    let split: PaneSplit
    let focusedLeafId: String
    let allowsPaneFocus: Bool

    @Environment(\.theme) var theme

    private let dividerThickness: CGFloat = 4
    @State private var isDividerHovering = false
    @State private var dragState = TerminalSplitDragState()

    var body: some View {
        GeometryReader { geo in
            let total: CGFloat = split.axis == .vertical ? geo.size.width : geo.size.height
            let usable = max(0, total - dividerThickness)
            let fraction = dragState.currentFraction ?? split.fraction
            let firstSize = max(20, usable * fraction)
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
                             node: split.children[0], focusedLeafId: focusedLeafId,
                             allowsPaneFocus: allowsPaneFocus, inSplit: true)
                    .frame(width: firstSize)
                    .clipped()
                dividerView(totalForFraction: totalForFraction)
                PaneNodeView(state: state, worktreeId: worktreeId, tabId: tabId,
                             node: split.children[1], focusedLeafId: focusedLeafId,
                             allowsPaneFocus: allowsPaneFocus, inSplit: true)
                    .frame(width: secondSize)
                    .clipped()
            }
        } else {
            VStack(spacing: 0) {
                PaneNodeView(state: state, worktreeId: worktreeId, tabId: tabId,
                             node: split.children[0], focusedLeafId: focusedLeafId,
                             allowsPaneFocus: allowsPaneFocus, inSplit: true)
                    .frame(height: firstSize)
                    .clipped()
                dividerView(totalForFraction: totalForFraction)
                PaneNodeView(state: state, worktreeId: worktreeId, tabId: tabId,
                             node: split.children[1], focusedLeafId: focusedLeafId,
                             allowsPaneFocus: allowsPaneFocus, inSplit: true)
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
                        _ = dragState.changed(
                            persistedFraction: split.fraction,
                            translation: delta,
                            totalForFraction: totalForFraction
                        )
                    }
                    .onEnded { _ in
                        let finalFraction = dragState.ended(fallback: split.fraction)
                        _ = state.tabs.setSplitFraction(
                            worktreeId: worktreeId, tabId: tabId,
                            splitId: split.id, fraction: finalFraction
                        )
                    }
            )
    }
}

struct TerminalSplitDragState {
    private var startFraction: Double?
    private(set) var currentFraction: Double?

    mutating func changed(
        persistedFraction: Double,
        translation: CGFloat,
        totalForFraction: CGFloat
    ) -> Double {
        let start = startFraction ?? Self.clamped(persistedFraction)
        startFraction = start

        guard totalForFraction > 0 else {
            currentFraction = start
            return start
        }

        let fraction = Self.clamped(start + Double(translation / totalForFraction))
        currentFraction = fraction
        return fraction
    }

    mutating func ended(fallback: Double) -> Double {
        let fraction = currentFraction ?? startFraction ?? Self.clamped(fallback)
        startFraction = nil
        currentFraction = nil
        return fraction
    }

    private static func clamped(_ fraction: Double) -> Double {
        max(0.1, min(0.9, fraction))
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
                Task { _ = try? await state.restoreTerminalTabIfNeededAsync(worktreeId: worktreeId, tabId: tabId) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-0"))
    }
}
