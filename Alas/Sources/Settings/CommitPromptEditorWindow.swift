import SwiftUI

struct CommitPromptEditorWindow: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draftPrompt = ""

    var body: some View {
        let theme = state.themeStore.current

        VStack(spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [theme.color("bg-3"), theme.color("bg-2")],
                    startPoint: .top, endPoint: .bottom
                )
                HStack {
                    TrafficLights()
                    Spacer()
                }
                .padding(.leading, 16)
                Text("Commit Prompt")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
            }
            .frame(height: 44)
            .overlay(Divider().opacity(0.5), alignment: .bottom)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Commit message prompt")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Instructions sent to the selected AI tool. The staged diff is appended on stdin.")
                            .font(.system(size: 12.5))
                            .foregroundColor(theme.color("fg-dim"))
                    }
                    Spacer()
                    AlasButton(title: "Reset to Default", style: .subtle) {
                        draftPrompt = AppConfig.defaultCommitPrompt
                    }
                }

                TextEditor(text: $draftPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(theme.color("bg-2"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.color("line-soft"), lineWidth: 0.5)
                    )
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.color("bg-1"))

            HStack(spacing: 8) {
                Spacer()
                AlasButton(title: "Cancel", style: .subtle) {
                    dismiss()
                }
                AlasButton(title: "Save", style: .primary) {
                    state.config.changes.prompt = draftPrompt
                    state.saveConfig()
                    dismiss()
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .background(theme.color("bg-2"))
            .overlay(Divider().opacity(0.5), alignment: .top)
        }
        .frame(width: 720, height: 560)
        .background(theme.color("bg-1"))
        .background(WindowConfigurator())
        .environment(\.theme, theme)
        .ignoresSafeArea()
        .onAppear {
            draftPrompt = state.config.changes.prompt
        }
    }
}
