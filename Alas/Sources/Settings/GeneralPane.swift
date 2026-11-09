import AppKit
import SwiftUI

struct GeneralPane: View {
    @Environment(\.designScale) private var scale
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("General").font(SettingsPaneStyle.titleFont)
                Text("Application behavior and updates.")
                    .font(scale.metaFont).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, scale.space[3])

                SettingsGroup(title: "Updates") {
                    SettingsRow(
                        name: "Automatically check for updates",
                        desc: "Check GitHub on launch and while Alas is running, at most once a day. New releases appear in Needs Attention."
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
            .padding(.horizontal, scale.space[5]).padding(.vertical, scale.space[5])
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
