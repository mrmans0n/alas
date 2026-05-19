import SwiftUI

struct RepoSelectorDialog: View {
    @Bindable var appState: AppState
    @Environment(\.theme) private var theme
    @FocusState private var inputFocused: Bool

    var body: some View {
        if appState.isRepoSelectorOpen {
            ZStack {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                VStack(spacing: 0) {
                    if case .worktrees(let projectId) = appState.repoSelector.step {
                        breadcrumb(projectId: projectId)
                    }
                    inputRow
                    Divider().background(theme.color("line"))
                    rowList
                    footer
                }
                .frame(width: 480)
                .frame(maxHeight: 520)
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
                inputFocused = true
            }
        }
    }

    // MARK: - Subviews

    private var inputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-faint"))
            TextField(placeholder, text: Bindable(appState.repoSelector).query)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .font(.system(size: 14))
                .foregroundColor(theme.color("fg"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var placeholder: String {
        switch appState.repoSelector.step {
        case .repos:
            return "Switch repository…"
        case .worktrees(let projectId):
            let name = appState.projects.first(where: { $0.id == projectId })?.name ?? ""
            return "Switch worktree in \(name)…"
        }
    }

    private func breadcrumb(projectId: String) -> some View {
        let name = appState.projects.first(where: { $0.id == projectId })?.name ?? ""
        return HStack(spacing: 6) {
            Image(systemName: "chevron.left")
                .font(.system(size: 10, weight: .semibold))
            Text(name)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(theme.color("fg-dim"))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { popToRepos() }
    }

    private var rowList: some View {
        let env = environment()
        let rows = appState.repoSelector.rows(environment: env)
        let projectsById = Dictionary(uniqueKeysWithValues: appState.projects.map { ($0.id, $0) })
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    RepoSelectorRowView(
                        row: row,
                        isSelected: idx == appState.repoSelector.selectedIndex,
                        projectsById: projectsById,
                        onTap: {
                            // Snap selection to the clicked row before
                            // activating so a tap without a preceding hover
                            // can't fire the stale keyboard selection.
                            appState.repoSelector.setSelectedIndex(idx, in: rows)
                            activate(rows: rows)
                        },
                        onHover: { appState.repoSelector.setSelectedIndex(idx, in: rows) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 200, maxHeight: 420)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            label("↑↓ navigate")
            label("↵ open")
            label("esc \(escLabel)")
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

    private var escLabel: String {
        switch appState.repoSelector.step {
        case .repos: return "close"
        case .worktrees: return "back"
        }
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
        case .pushed:
            inputFocused = true
        case .noop:
            break
        }
    }

    private func popToRepos() {
        appState.repoSelector.popToRepos()
        inputFocused = true
    }

    private func close() {
        appState.repoSelector.close()
        appState.isRepoSelectorOpen = false
    }

    // MARK: - Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let model = appState.repoSelector
        let env = environment()
        let rows = model.rows(environment: env)
        switch press.key {
        case .escape:
            switch model.step {
            case .repos:
                close()
            case .worktrees:
                popToRepos()
            }
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
        default:
            return .ignored
        }
    }
}
