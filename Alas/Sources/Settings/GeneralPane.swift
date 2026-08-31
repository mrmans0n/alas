import AppKit
import SwiftUI

struct GeneralPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("General").font(.system(size: 18, weight: .semibold))
                Text("Application behavior and updates.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Updates") {
                    SettingsRow(
                        name: "Automatically check for updates",
                        desc: "Check GitHub for new releases on launch, at most once a day."
                    ) {
                        AlasToggle(on: state.bind(\.general.autoUpdate))
                    }
                }

                SettingsGroup(title: "Repositories") {
                    SettingsRow(
                        name: "Default clone folder",
                        desc: "Used when cloning repositories from GitHub, GitLab, or a Git URL."
                    ) {
                        HStack(spacing: 6) {
                            AlasField(
                                text: state.bind(\.repositoryCloneRootPath),
                                placeholder: "Choose on first clone",
                                monospaced: true
                            )
                            .frame(width: 220)
                            AlasButton(title: "Choose…", action: chooseCloneFolder)
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }

    private func chooseCloneFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.config.repositoryCloneRootPath = url.path
            state.saveConfig()
        }
    }
}
