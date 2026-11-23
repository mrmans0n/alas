import SwiftUI

struct CodeReviewPromptEditorWindow: View {
    @Bindable var state: AppState
    @State private var draftPrompt = ""

    var body: some View {
        PromptEditorBody(
            windowTitle: "Code Review Prompt",
            title: "Code review prompt",
            description: "What every review looks for. Project instructions and .alas/code-review.md are added after it.",
            draftPrompt: $draftPrompt,
            onReset: { draftPrompt = CodeReviewSettings.defaultPrompt },
            onCancel: { closeWindow() },
            onSave: {
                state.config.changes.codeReview.prompt = draftPrompt
                state.saveConfig()
                closeWindow()
            },
            theme: state.themeStore.current
        )
        .onAppear { draftPrompt = state.config.changes.codeReview.prompt }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}
