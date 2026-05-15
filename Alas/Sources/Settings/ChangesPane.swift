import SwiftUI

struct ChangesPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Changes").font(.system(size: 18, weight: .semibold))
                Text("AI-generated commit messages and related defaults.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Commit message") {
                    SettingsRow(name: "Tool",
                                desc: "Used by the sparkle button in the commit composer.") {
                        toolPicker
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }

    private var toolPicker: some View {
        Picker("", selection: state.bind(\.changes.aiToolId)) {
            ForEach(menuItems, id: \.id) { item in
                Text(item.label).tag(item.id)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 240)
    }

    private struct MenuItem: Identifiable { let id: String; let label: String }

    private var menuItems: [MenuItem] {
        var items: [MenuItem] = []
        for tool in CommitAITool.detectable {
            let detected = state.availableCommitAITools.contains(tool)
            items.append(MenuItem(
                id: tool.id,
                label: detected ? tool.label : "\(tool.label) (not detected)"
            ))
        }
        items.append(MenuItem(id: CommitAITool.none.id, label: CommitAITool.none.label))
        return items
    }
}
