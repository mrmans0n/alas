import SwiftUI

struct TerminalPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    @State private var hookStatus: [AgentKind: String] = [:]
    private let installerRegistry = AgentInstallerRegistry()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Terminal").font(.system(size: 18, weight: .semibold))
                Text("The Ghostty terminal embedded in the center pane.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Shell") {
                    SettingsRow(name: "Default shell", desc: "Path to the shell executable.") {
                        AlasField(text: state.bind(\.terminal.shell), monospaced: true)
                    }
                    // "Last used" intentionally omitted: TerminalService
                    // doesn't track per-session cwd yet (resolveWorkingDirectory
                    // would silently fall through to the worktree root). It'll
                    // come back here once that tracking lands.
                    SettingsRow(name: "Working directory") {
                        Seg(value: state.bind(\.terminal.workingDirectory), options: [
                            ("worktreeRoot", "Worktree root"),
                            ("repoRoot", "Repo root"),
                        ])
                    }
                }

                SettingsGroup(title: "Startup scripts") {
                    SettingsRow(name: "Run on session open",
                                desc: "Executed in every new terminal pane after the shell starts.") {
                        TextEditor(text: state.bind(\.terminal.startupScript))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.color("fg"))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 80)
                            .padding(8)
                            .background(theme.color("bg-0"))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
                    }
                    SettingsRow(name: "Run on worktree create",
                                desc: "Executed once after a worktree is created.") {
                        TextEditor(text: state.bind(\.terminal.worktreeCreateScript))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.color("fg"))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 60)
                            .padding(8)
                            .background(theme.color("bg-0"))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
                    }
                    SettingsRow(name: "Inherit parent env",
                                desc: "Pass environment from launching shell into terminals.") {
                        AlasToggle(on: state.bind(\.terminal.inheritParentEnv))
                    }
                }

                SettingsGroup(title: "Appearance") {
                    SettingsRow(name: "Font family") {
                        FontFamilyPicker(
                            family: state.bind(\.terminal.fontFamily),
                            catalog: MonospaceFontCatalog.families()
                        )
                    }
                    SettingsRow(name: "Font size") {
                        AlasField(text: Binding(
                            get: { String(state.config.terminal.fontSize) },
                            set: {
                                let raw = Int($0) ?? 13
                                state.config.terminal.fontSize = max(8, min(64, raw))
                                state.saveConfig()
                            }
                        ), monospaced: true).frame(width: 80)
                    }
                    SettingsRow(name: "Cursor style") {
                        Seg(value: state.bind(\.terminal.cursorStyle), options: [
                            ("block","block"), ("beam","beam"), ("underline","underline")
                        ])
                    }
                    SettingsRow(name: "Cursor blink") {
                        AlasToggle(on: state.bind(\.terminal.cursorBlink))
                    }
                    SettingsRow(name: "Scrollback lines") {
                        AlasField(text: Binding(
                            get: { String(state.config.terminal.scrollbackLines) },
                            set: { state.config.terminal.scrollbackLines = Int($0) ?? 10000
                            state.saveConfig() }
                        ), monospaced: true).frame(width: 100)
                    }
                    SettingsRow(name: "Bell") {
                        Seg(value: state.bind(\.terminal.bell), options: [
                            ("off","off"), ("visual","visual"), ("sound","sound")
                        ])
                    }
                }

                SettingsGroup(title: "Harness") {
                    SettingsRow(name: "Notify when AI harness finishes",
                                desc: "Show a macOS notification when a detected harness completes.") {
                        AlasToggle(on: Binding(
                            get: { state.config.harness.notifyOnFinish },
                            set: { state.config.harness.notifyOnFinish = $0
                            state.saveConfig()
                            state.harness.notifications.setEnabled($0) }
                        ))
                    }
                    SettingsRow(name: "Notify when AI harness needs input",
                                desc: "Show a clickable notification when a detected harness is waiting for input.") {
                        AlasToggle(on: state.bind(\.harness.notifyOnAwaiting))
                    }
                    ForEach(installerRegistry.supportedAgents) { agent in
                        SettingsRow(name: agent.displayName) {
                            HStack {
                                let state = installerRegistry.installer(for: agent)?.installState() ?? .notInstalled
                                AlasButton(
                                    title: state == .installed ? "Reinstall" : state == .outdated ? "Update" : "Install",
                                    action: { installAgent(agent) }
                                )
                                if state == .installed {
                                    AlasButton(title: "Uninstall", action: { uninstallAgent(agent) })
                                }
                                if let status = hookStatus[agent] {
                                    Text(status).font(.system(size: 11))
                                        .foregroundColor(theme.color("fg-dim"))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }

    private func installAgent(_ agent: AgentKind) {
        guard let installer = installerRegistry.installer(for: agent) else { return }
        Task {
            do {
                try await installer.install()
                hookStatus[agent] = "Installed"
            } catch {
                hookStatus[agent] = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func uninstallAgent(_ agent: AgentKind) {
        guard let installer = installerRegistry.installer(for: agent) else { return }
        do {
            try installer.uninstall()
            hookStatus[agent] = nil
        } catch {
            hookStatus[agent] = "Error: \(error.localizedDescription)"
        }
    }
}
