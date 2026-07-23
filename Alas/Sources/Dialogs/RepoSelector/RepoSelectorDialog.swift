import AppKit
import SwiftUI

struct RepoSelectorDialog: View {
    @Bindable var appState: AppState
    @Environment(\.theme) private var theme
    @FocusState private var inputFocused: Bool
    /// Screen-coords cursor position from the most recently accepted hover.
    /// Used to ignore hovers that fire because the row scrolled under a
    /// stationary cursor (rather than the cursor actually moving). Without
    /// this guard, keyboard navigation fights with the scrolled-into-place
    /// row claiming hover and snapping selection back.
    @State private var lastHoverLocation: CGPoint?

    var body: some View {
        if appState.isRepoSelectorOpen {
            ZStack {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                VStack(spacing: 0) {
                    inputRow
                    rowList
                    footer
                }
                .onChange(of: appState.repoSelector.query) { _, _ in
                    // After a query change, model.didSet has reset
                    // selectedIndex to 0. In empty-query mode row 0 is a
                    // header (RECENT/PROJECT), which isn't selectable —
                    // snap forward to the nearest selectable row using the
                    // fresh row list.
                    let env = environment()
                    let rows = appState.repoSelector.rows(environment: env)
                    appState.repoSelector.setSelectedIndex(0, in: rows)
                }
                .frame(width: 720)
                .background(theme.color("bg-1").opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
                .padding(.top, 70)
                .frame(maxHeight: .infinity, alignment: .top)
                .onTapGesture { /* swallow */ }
                .onKeyPress { press in handleKey(press) }
            }
            .transition(.opacity.combined(with: .offset(y: -6)))
            .onAppear {
                appState.repoSelector.open()
                // `open()` resets query to "" — but if it was already "",
                // didSet skips and selectedIndex stays at 0, which lands on
                // the RECENT or first project header (non-selectable). Snap
                // forward so ↵ on first open activates the top worktree.
                let rows = appState.repoSelector.rows(environment: environment())
                appState.repoSelector.setSelectedIndex(0, in: rows)
                requestInputFocus()
            }
            .onChange(of: appState.isRepoSelectorOpen) { _, isOpen in
                if isOpen { requestInputFocus() }
            }
        }
    }

    // MARK: - Subviews

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(theme.color("fg-dim"))
            TextField("Switch worktree…", text: Bindable(appState.repoSelector).query)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .font(.system(size: 15))
                .foregroundColor(theme.color("fg"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(
            Rectangle()
                .fill(theme.color("line-soft"))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var rowList: some View {
        let env = environment()
        let rows = appState.repoSelector.rows(environment: env)
        let renderedRows = rows.enumerated().map { RepoSelectorRenderedRow(index: $0.offset, row: $0.element) }
        let projectsById = Dictionary(uniqueKeysWithValues: appState.projects.map { ($0.id, $0) })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(renderedRows) { renderedRow in
                        RepoSelectorRowView(
                            row: renderedRow.row,
                            isSelected: renderedRow.index == appState.repoSelector.selectedIndex,
                            projectsById: projectsById,
                            onTap: {
                                // Snap selection to the clicked row before
                                // activating so a tap without a preceding hover
                                // can't fire the stale keyboard selection.
                                appState.repoSelector.setSelectedIndex(renderedRow.index, in: rows)
                                activate(rows: rows)
                            },
                            onHover: {
                                let current = NSEvent.mouseLocation
                                if lastHoverLocation == current { return }
                                lastHoverLocation = current
                                appState.repoSelector.setSelectedIndex(renderedRow.index, in: rows)
                            }
                        )
                        // `RepoSelectorRenderedRow.id` is `"<index>:<stableId>"`
                        // — unique (the same worktree can appear in both the
                        // Recent and project sections, so a bare stableId would
                        // collide) and content-aware (the stableId component
                        // changes when the row at a position changes, so
                        // LazyVStack rebuilds instead of caching a stale row).
                        .id(renderedRow.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 200, maxHeight: 420)
            .onChange(of: appState.repoSelector.scrollToSelectionTick) { _, _ in
                // anchor: nil scrolls just enough to make the row visible.
                // .center would re-center on every arrow press, shifting the
                // list under the cursor and triggering hover-induced
                // selection bouncing.
                let index = appState.repoSelector.selectedIndex
                if renderedRows.indices.contains(index) {
                    proxy.scrollTo(renderedRows[index].id)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            label("↑↓ navigate")
            label("↵ open")
            label("esc close")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2").opacity(0.5))
        .overlay(
            Rectangle().fill(theme.color("line-soft")).frame(height: 0.5),
            alignment: .top
        )
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-faint"))
    }

    // MARK: - Actions

    private func environment() -> RepoSelectorEnvironment {
        appState.repoSelectorEnvironment(
            openNewProject: {
                NotificationCenter.default.post(name: .alasCreateProject, object: nil)
            },
            openNewWorktree: { projectId in
                NotificationCenter.default.post(name: .alasNewWorktree, object: projectId)
            }
        )
    }

    private func activate(rows: [RepoSelectorRow]) {
        let env = environment()
        let result = appState.repoSelector.activate(rows: rows, environment: env)
        switch result {
        case .focused, .openedNewWorktree, .openedNewProject:
            appState.isRepoSelectorOpen = false
        case .noop:
            break
        }
    }

    private func close() {
        appState.repoSelector.close()
        appState.isRepoSelectorOpen = false
    }

    private func requestInputFocus() {
        inputFocused = false
        DispatchQueue.main.async {
            inputFocused = true
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }

    // MARK: - Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let model = appState.repoSelector
        let env = environment()
        let rows = model.rows(environment: env)
        switch press.key {
        case .escape:
            close()
            return .handled
        case .upArrow:
            model.moveSelectionUp(in: rows)
            return .handled
        case .downArrow:
            model.moveSelectionDown(in: rows)
            return .handled
        case .return:
            activate(rows: rows)
            return .handled
        case .tab:
            // The no-projects empty hint advertises "Press ⇥ to add one".
            // Honor that here; everywhere else Tab is left alone.
            let safeIndex = max(0, min(rows.count - 1, model.selectedIndex))
            if rows.indices.contains(safeIndex), case .emptyHint = rows[safeIndex] {
                activate(rows: rows)
                return .handled
            }
            return .ignored
        default:
            return .ignored
        }
    }
}
