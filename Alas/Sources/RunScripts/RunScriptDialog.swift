import SwiftUI

struct RunScriptDialog: View {
    @Bindable var appState: AppState
    let selectedWorktree: () -> Worktree?
    @Environment(\.theme) private var theme
    @FocusState private var inputFocused: Bool
    @State private var environment: RunScriptPaletteEnvironment?

    var body: some View {
        Group {
            if appState.isRunScriptPaletteOpen {
                ZStack {
                    Color.black.opacity(0.42)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                    VStack(spacing: 0) {
                        inputRow
                        Divider().background(theme.color("line"))
                        rowList
                        footer
                    }
                    .frame(width: 460)
                    .frame(maxHeight: 420)
                    .background(theme.color("bg-1").opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(theme.color("line"), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
                    .padding(.top, 70)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .onTapGesture { }
                    .onKeyPress { press in handleKey(press) }
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .onChange(of: appState.isRunScriptPaletteOpen) { _, isOpen in
            if isOpen {
                guard let worktree = selectedWorktree() else {
                    appState.isRunScriptPaletteOpen = false
                    return
                }
                let env = appState.runScriptPaletteEnvironment(worktree: worktree)
                environment = env
                appState.runScriptPalette.load(environment: env)
                requestInputFocus()
            } else {
                environment = nil
            }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Icon(name: "play", size: 12, color: theme.color("fg-faint"))
            TextField("Run script…", text: Bindable(appState.runScriptPalette).query)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .font(.system(size: 14))
                .foregroundColor(theme.color("fg"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var rowList: some View {
        let rows = appState.runScriptPalette.rows()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isEmpty(rows) {
                        emptyState
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                            rowView(row, index: idx)
                                .id(idx)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 180, maxHeight: 320)
            .onChange(of: appState.runScriptPalette.scrollToSelectionTick) { _, _ in
                proxy.scrollTo(appState.runScriptPalette.selectedIndex, anchor: .center)
            }
        }
    }

    /// True when there are no discovered scripts and the only rows are the
    /// trailing "New …" actions.
    private func isEmpty(_ rows: [RunScriptPaletteModel.Row]) -> Bool {
        appState.runScriptPalette.scripts.isEmpty
            && rows.allSatisfy { row in
                switch row {
                case .newRepoScript, .newGlobalScript: return true
                default: return false
                }
            }
    }

    @ViewBuilder
    private func rowView(_ row: RunScriptPaletteModel.Row, index: Int) -> some View {
        switch row {
        case .header(let title):
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(theme.color("fg-faint"))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 3)
        case .script(let script):
            scriptRow(script, isSelected: index == appState.runScriptPalette.selectedIndex)
                .onTapGesture {
                    appState.runScriptPalette.setSelectedIndex(index)
                    activate()
                }
                .onHover { hovering in
                    if hovering { appState.runScriptPalette.setSelectedIndex(index) }
                }
        case .newRepoScript:
            newScriptRow("New Repo Script…", isSelected: index == appState.runScriptPalette.selectedIndex)
                .onTapGesture {
                    appState.runScriptPalette.setSelectedIndex(index)
                    activate()
                }
                .onHover { hovering in
                    if hovering { appState.runScriptPalette.setSelectedIndex(index) }
                }
        case .newGlobalScript:
            newScriptRow("New Global Script…", isSelected: index == appState.runScriptPalette.selectedIndex)
                .onTapGesture {
                    appState.runScriptPalette.setSelectedIndex(index)
                    activate()
                }
                .onHover { hovering in
                    if hovering { appState.runScriptPalette.setSelectedIndex(index) }
                }
        }
    }

    private func scriptRow(_ script: RunScript, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Icon(name: "play", size: 11, color: theme.color("fg-muted"))
            VStack(alignment: .leading, spacing: 1) {
                Text(script.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                Text(script.fileName)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if environment?.isRunning(script) == true {
                Circle()
                    .fill(theme.color("add"))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(isSelected ? theme.color("bg-3") : .clear)
        .contentShape(Rectangle())
    }

    private func newScriptRow(_ title: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-muted"))
                .frame(width: 11)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundColor(theme.color("fg"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(isSelected ? theme.color("bg-3") : .clear)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No run scripts yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-dim"))
            Text("Scripts live in .alas/scripts/ in the repo.")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            label("↑↓ navigate")
            label("↵ run / focus")
            label("⌘↵ restart")
            label("⌘E edit")
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

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-faint"))
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            close()
            return .handled
        case .upArrow:
            appState.runScriptPalette.moveSelection(step: -1)
            return .handled
        case .downArrow:
            appState.runScriptPalette.moveSelection(step: 1)
            return .handled
        case .return:
            if press.modifiers.contains(.command) {
                restart()
            } else {
                activate()
            }
            return .handled
        default:
            if press.characters == "e", press.modifiers.contains(.command) {
                edit()
                return .handled
            }
            return .ignored
        }
    }

    private func activate() {
        guard let environment else { return }
        appState.runScriptPalette.activateSelection(environment: environment)
        close()
    }

    private func restart() {
        guard let environment else { return }
        appState.runScriptPalette.restartSelection(environment: environment)
        close()
    }

    private func edit() {
        guard let environment else { return }
        appState.runScriptPalette.editSelection(environment: environment)
        close()
    }

    private func close() {
        appState.runScriptPalette.reset()
        appState.isRunScriptPaletteOpen = false
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
}
