import SwiftUI

struct MarkdownPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Markdown").font(.system(size: 18, weight: .semibold))
                Text("Rendering and default view mode for markdown files.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "View") {
                    SettingsRow(name: "Default view mode",
                                desc: "Initial mode when a markdown file is opened.") {
                        Picker("", selection: Binding(
                            get: { state.config.markdown.defaultViewMode },
                            set: {
                                state.config.markdown.defaultViewMode = $0
                                state.saveConfig()
                            }
                        )) {
                            Text("Editor").tag(MarkdownViewMode.editor)
                            Text("Split").tag(MarkdownViewMode.split)
                            Text("Preview").tag(MarkdownViewMode.preview)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }
}
