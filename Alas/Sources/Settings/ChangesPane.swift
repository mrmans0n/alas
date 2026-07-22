import SwiftUI

struct ChangesPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    @Environment(\.openWindow) private var openWindow
    @State private var ggInstall = GGInstallController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Changes").font(.system(size: 18, weight: .semibold))
                Text("AI-generated commit messages and merge-conflict resolution.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Comparison base") {
                    SettingsRow(
                        name: "Compare commits against",
                        desc: comparisonModeDescription
                    ) {
                        Picker("", selection: state.bind(\.changes.comparisonMode)) {
                            Text("Auto").tag(AppConfig.Changes.ChangesComparisonMode.auto)
                            Text("Branch upstream").tag(AppConfig.Changes.ChangesComparisonMode.branchUpstream)
                            Text("Manual").tag(AppConfig.Changes.ChangesComparisonMode.manual)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                SettingsGroup(title: "Commit message") {
                    SettingsRow(name: "Agent",
                                desc: "Used by the sparkle button in the draft commit tab.") {
                        toolPicker
                    }
                    SettingsRow(name: "Prompt",
                                desc: "Instructions sent to the CLI. The staged diff is appended on stdin.") {
                        promptEditorRow(
                            windowId: "commit-prompt-editor",
                            currentValue: state.config.changes.prompt,
                            defaultValue: AppConfig.defaultCommitPrompt
                        )
                    }
                }

                SettingsGroup(title: "Review requests") {
                    SettingsRow(
                        name: "Prompt",
                        desc: "Used by the sparkle button in the draft PR tab. The committed branch diff is appended on stdin."
                    ) {
                        promptEditorRow(
                            windowId: "review-request-prompt-editor",
                            currentValue: state.config.changes.reviewRequestPrompt,
                            defaultValue: AppConfig.defaultReviewRequestPrompt
                        )
                    }
                }

                SettingsGroup(title: "Stacked diffs") {
                    SettingsRow(
                        name: "git-gud (gg)",
                        desc: GGAvailability.shared.isInstalled
                            ? "Stack-aware commits section, synced from gg."
                            : "Installs via Homebrew: brew install mrmans0n/tap/gg-stack"
                    ) {
                        ggStatusControl
                    }
                    SettingsRow(
                        name: "Enable stacked diffs",
                        desc: "Master switch. Off hides all gg UI everywhere."
                    ) {
                        Toggle("", isOn: state.bind(\.changes.stackedDiffsEnabled))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(!GGAvailability.shared.isInstalled)
                            .onChange(of: state.config.changes.stackedDiffsEnabled) { _, _ in
                                state.rightPaneStore.reevaluateGGGates()
                            }
                    }
                    SettingsRow(
                        name: "Default for linked worktrees",
                        desc: "Main worktrees default Off. Override individual worktrees from their sidebar menu."
                    ) {
                        EmptyView()
                    }
                    ForEach(state.projectsManager.projects) { project in
                        SettingsRow(name: project.name, desc: "") {
                            Picker("", selection: ggModeBinding(project)) {
                                Text("Off").tag(GGProjectMode.off)
                                Text("Auto").tag(GGProjectMode.auto)
                                Text("On").tag(GGProjectMode.on)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .disabled(!GGAvailability.shared.isInstalled
                                      || !state.config.changes.stackedDiffsEnabled)
                        }
                    }
                }

                SettingsGroup(title: "Merge conflicts") {
                    SettingsRow(name: "Bulk resolve prompt",
                                desc: "Sent to the agent CWD'd at the worktree when the user clicks 'Resolve all with agent'. The agent uses its own tools to enumerate, reconcile, and stage every conflicted file.") {
                        promptEditorRow(
                            windowId: "merge-bulk-prompt-editor",
                            currentValue: state.config.changes.mergeBulkResolvePrompt,
                            defaultValue: AppConfig.defaultMergeBulkResolvePrompt
                        )
                    }
                    SettingsRow(name: "Single-file prompt",
                                desc: "Used by 'Ask agent to resolve' in the merge editor toolbar. The three sides are appended automatically.") {
                        promptEditorRow(
                            windowId: "merge-single-prompt-editor",
                            currentValue: state.config.changes.mergeSingleResolvePrompt,
                            defaultValue: AppConfig.defaultMergeSingleResolvePrompt
                        )
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .task {
            // Wait for the login-shell PATH first, same as the startup probe
            // in AppState — otherwise opening Settings early (e.g. right
            // after a Finder/Dock launch) can win the race and cache a
            // Homebrew-only `gg` as missing before PATH resolution finishes,
            // since this is a non-force probe and `hasProbed` latches.
            await ShellEnvResolver.shared.waitUntilResolved()
            await GGAvailability.shared.probe()
        }
        .onChange(of: ggInstall.phase) { _, newPhase in
            // Right-pane states that already evaluated the gate while gg was
            // absent are otherwise never asked to re-check it, so an install
            // completed with a pane open would leave the stack UI missing
            // until an unrelated refresh happened to fire.
            if newPhase == .succeeded {
                state.rightPaneStore.reevaluateGGGates()
            }
        }
    }

    private var comparisonModeDescription: String {
        switch state.config.changes.comparisonMode {
        case .auto:
            return "Compares against origin/<base> (falls back to your local base branch). Always shows this branch's own work and stays stable across rebases."
        case .branchUpstream:
            return "Compares against this branch's own remote tracking ref, so it only lists unpushed commits once you push."
        case .manual:
            return "Compares against the base branch you pick per worktree (via the base-branch selector), resolved locally first."
        }
    }

    /// Edit button + Custom chip, grouped together. Previously this row
    /// used a `Spacer()` between the two, which left them visually
    /// disconnected — flagged as "awful and unaligned" during dogfooding.
    private func promptEditorRow(
        windowId: String,
        currentValue: String,
        defaultValue: String
    ) -> some View {
        HStack(spacing: 8) {
            AlasButton(title: "Edit", style: .normal) {
                openWindow(id: windowId)
            }
            if let label = CommitPromptStatus.chipLabel(for: currentValue, defaultPrompt: defaultValue) {
                PromptStatusChip(label: label)
            }
        }
    }

    private var toolPicker: some View {
        Picker("", selection: state.bind(\.changes.aiToolId)) {
            // `agent.isEnabled` is clamped against install detection in
            // AgentRegistry, so every entry here is both enabled and installed.
            ForEach(state.agentRegistry.agents.filter(\.isEnabled)) { agent in
                Label {
                    Text(agent.displayName)
                } icon: {
                    Image(nsImage: AgentLogoView.menuImage(for: agent, size: 14))
                }
                .tag(agent.id)
            }
            Text("None").tag("none")
        }
        .pickerStyle(.menu)
        .settingsDropdownFrame()
    }

    @ViewBuilder
    private var ggStatusControl: some View {
        switch ggInstall.phase {
        case .running:
            HStack(spacing: 6) {
                Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 10, height: 10)
                Text("Installing…")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("warn"))
                    .lineLimit(2)
                AlasButton(title: "Retry", style: .normal) { ggInstall.install() }
            }
        case .idle, .succeeded:
            if let version = GGAvailability.shared.version {
                Text("gg \(version)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg-muted"))
            } else {
                AlasButton(title: "Install gg…", style: .normal) { ggInstall.install() }
            }
        }
    }

    private func ggModeBinding(_ project: ProjectConfig) -> Binding<GGProjectMode> {
        Binding(
            get: {
                state.projectsManager.projects.first { $0.id == project.id }?.ggMode ?? .auto
            },
            set: { newMode in
                state.projectsManager.setGGMode(projectId: project.id, mode: newMode)
                _ = state.saveProjects()
                state.rightPaneStore.reevaluateGGGates()
            }
        )
    }
}

private struct PromptStatusChip: View {
    let label: String
    @Environment(\.theme) var theme

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.color("fg-muted"))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(theme.color("bg-2"))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(theme.color("line-soft"), lineWidth: 0.5)
            )
    }
}
