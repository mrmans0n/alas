import SwiftUI

/// Commands, their observed state, and their endpoints for one worktree.
///
/// Scripts are rescanned on appear (the palette does the same — the directory
/// holds a handful of small files), while run state comes from
/// `AppState.runRecords`, which outlives this view. Hiding or switching the
/// panel therefore never touches a running command.
struct RunTabView: View {
    @Bindable var state: AppState
    let worktree: Worktree

    @Environment(\.theme) private var theme
    @State private var scripts: [RunScript] = []
    @State private var scriptCatalogError: String?
    /// Keeps the "no scripts yet" copy from flashing before the first scan.
    @State private var hasScanned = false
    /// Drives the relative timestamps ("3m ago") without re-scanning anything.
    @State private var now = Date()
    /// Held in `@State` so `onReceive` keeps one stable subscription instead
    /// of restarting the interval on every body pass.
    @State private var ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if !hasScanned {
                Color.clear
            } else if let scriptCatalogError {
                errorState(scriptCatalogError)
            } else if scripts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(RunScriptScope.allCases, id: \.self) { scope in
                            let scoped = scripts.filter { $0.scope == scope }
                            if !scoped.isEmpty {
                                RunScopeHeader(title: scope.sectionTitle, count: scoped.count)
                                ForEach(scoped) { script in
                                    RunRowView(
                                        presentation: presentation(for: script),
                                        onAction: { perform($0, script: script) }
                                    )
                                }
                            }
                        }
                        newScriptFooter
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: worktree.id) {
            await refreshScripts()
            hasScanned = true
            // Reconnecting to a worktree is the moment to settle runs whose
            // terminal disappeared while nothing was watching them.
            state.reconcileRunRecords(worktreeID: worktree.id)
            now = Date()
        }
        .onReceive(ticker) { now = $0 }
        .onChange(of: state.runScriptCatalogGeneration) {
            Task {
                await refreshScripts()
                hasScanned = true
            }
        }
    }

    private func presentation(for script: RunScript) -> RunRowPresentation {
        RunTabPresentation.row(
            RunRowInput(
                script: script,
                record: state.runRecords.record(worktreeID: worktree.id, scriptKey: script.key),
                hasTerminal: state.runningScriptTab(for: script, in: worktree) != nil,
                hasCapturedOutput: state.runRecords.record(worktreeID: worktree.id, scriptKey: script.key)
                    .flatMap { record in
                        record.failureID.map { failureID in
                            state.runScriptFailures(in: worktree.id).contains { $0.id == failureID }
                        }
                    } ?? false,
                target: state.runExecutionTarget(for: script, in: worktree)
            ),
            now: now
        )
    }

    private func perform(_ action: RunRowAction, script: RunScript) {
        Task {
            await perform(action, matching: script)
        }
    }

    private func perform(_ action: RunRowAction, matching staleScript: RunScript) async {
        switch action {
        case .start:
            let script = await freshScript(matching: staleScript) ?? staleScript
            if case .finished? = state.runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.status {
                state.restartScript(script, in: worktree)
            } else if state.scriptTab(for: script, in: worktree) != nil {
                state.restartScript(script, in: worktree)
            } else {
                state.runOrFocusScript(script, in: worktree)
            }
        case .stop:
            state.stopScript(staleScript, in: worktree)
        case .restart:
            state.stopScript(staleScript, in: worktree)
            let script = await freshScript(matching: staleScript) ?? staleScript
            state.restartScript(script, in: worktree)
        case .openTerminal:
            state.focusScriptTerminal(staleScript, in: worktree)
        case .openEndpoint:
            let script = await freshScript(matching: staleScript) ?? staleScript
            state.openRunEndpoint(script, in: worktree)
        case .showOutput(let failureID):
            guard let failure = state.runScriptFailures(in: worktree.id).first(where: { $0.id == failureID })
            else { return }
            state.presentRunScriptFailure(failure)
        case .edit:
            state.editScript(staleScript, in: worktree)
        }
    }

    @discardableResult
    private func refreshScripts() async -> [RunScript] {
        let host = RemoteHostRegistry.shared.host(forPath: worktree.path.path)
        let result = await RunScriptStore.discoverScripts(worktreeRoot: worktree.path, remoteHost: host)
        guard !Task.isCancelled else { return scripts }
        switch result {
        case .scripts(let fresh):
            scriptCatalogError = nil
            scripts = fresh
            return fresh
        case .failed(let message):
            scriptCatalogError = message
            return scripts
        }
    }

    private func freshScript(matching script: RunScript) async -> RunScript? {
        let fresh = await refreshScripts()
        return fresh.first { $0.key == script.key }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Icon(name: "play", size: 22, color: theme.color("fg-faint"))
            Text("No run scripts yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
            Text("Add a script to \(RunScriptStore.repoScriptsRelativeDir) to build, test, or serve this worktree.")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("New Repo Script") { state.newRunScript(scope: .repo, in: worktree) }
                Button("New Global Script") { state.newRunScript(scope: .global, in: worktree) }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("run-tab-empty-state")
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Icon(name: "exclamationmark.triangle", size: 22, color: theme.color("warn"))
            Text("Couldn’t Load Run Scripts")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task {
                    await refreshScripts()
                    hasScanned = true
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("run-tab-error-state")
    }

    private var newScriptFooter: some View {
        HStack(spacing: 8) {
            Button("New Repo Script") { state.newRunScript(scope: .repo, in: worktree) }
            Button("New Global Script") { state.newRunScript(scope: .global, in: worktree) }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct RunScopeHeader: View {
    let title: String
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(theme.color("seg-pill-bg"))
                .clipShape(Capsule())
                .foregroundColor(theme.color("fg-muted"))
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(theme.color("section-head-bg"))
    }
}

private struct RunRowView: View {
    let presentation: RunRowPresentation
    let onAction: (RunRowAction) -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RunStatusDot(tone: presentation.tone, isActive: presentation.isActive)
                Text(presentation.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(presentation.statusLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(toneColor)
            }

            if let detail = presentation.detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
            }

            if let location = presentation.locationLabel {
                HStack(spacing: 4) {
                    Icon(name: "terminal", size: 9, color: theme.color("fg-faint"))
                    Text(location)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.color("fg-faint"))
                        .lineLimit(1)
                }
            }

            if let conflict = presentation.conflictLabel {
                HStack(spacing: 4) {
                    Icon(name: "exclamationmark.triangle", size: 9, color: theme.color("warn"))
                    Text(conflict)
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("warn"))
                        .lineLimit(2)
                }
            }

            HStack(spacing: 6) {
                ForEach(Array(presentation.actions.enumerated()), id: \.offset) { _, action in
                    Button(label(for: action)) { onAction(action) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(theme.color("accent"))
                        .accessibilityLabel("\(label(for: action)) \(presentation.name)")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? theme.color("bg-3") : .clear)
        .overlay(Divider().opacity(0.4), alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(presentation.locationDetail)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("run-row-\(presentation.id)")
    }

    private var toneColor: Color {
        switch presentation.tone {
        case .idle:    theme.color("fg-faint")
        case .active:  theme.color("accent")
        case .success: theme.color("add")
        case .failure: theme.color("del")
        case .warning: theme.color("warn")
        }
    }

    private func label(for action: RunRowAction) -> String {
        switch action {
        case .start(let label): label
        case .stop:             "Stop"
        case .restart:          "Restart"
        case .openTerminal:     "Terminal"
        case .openEndpoint:     "Open"
        case .showOutput:       "Output"
        case .edit:             "Edit"
        }
    }
}

private struct RunStatusDot: View {
    let tone: RunStatusTone
    let isActive: Bool

    @Environment(\.theme) private var theme
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(isActive && pulsing ? 0.35 : 1)
            .animation(
                isActive ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: pulsing
            )
            .onAppear { pulsing = isActive }
            .onChange(of: isActive) { _, active in pulsing = active }
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .idle:    theme.color("fg-faint")
        case .active:  theme.color("accent")
        case .success: theme.color("add")
        case .failure: theme.color("del")
        case .warning: theme.color("warn")
        }
    }
}
