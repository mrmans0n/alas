import SwiftUI

struct CommitPromptEditorWindow: View {
    @Bindable var state: AppState
    @State private var draftPrompt = ""

    var body: some View {
        PromptEditorBody(
            windowTitle: "Commit Prompt",
            title: "Commit message prompt",
            description: "Instructions sent to the selected AI tool. The staged diff is appended on stdin.",
            draftPrompt: $draftPrompt,
            onReset: { draftPrompt = AppConfig.defaultCommitPrompt },
            onCancel: { closeWindow() },
            onSave: {
                state.config.changes.prompt = draftPrompt
                state.saveConfig()
                closeWindow()
            },
            theme: state.themeStore.current
        )
        .onAppear { draftPrompt = state.config.changes.prompt }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}
