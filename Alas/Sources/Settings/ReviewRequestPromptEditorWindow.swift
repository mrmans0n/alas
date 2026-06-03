import SwiftUI

struct ReviewRequestPromptEditorWindow: View {
    @Bindable var state: AppState
    @State private var draftPrompt = ""

    var body: some View {
        PromptEditorBody(
            windowTitle: "Review Request Prompt",
            title: "Review request prompt",
            description: "Instructions sent to the selected AI tool. The committed branch diff is appended on stdin.",
            draftPrompt: $draftPrompt,
            onReset: { draftPrompt = AppConfig.defaultReviewRequestPrompt },
            onCancel: { closeWindow() },
            onSave: {
                state.config.changes.reviewRequestPrompt = draftPrompt
                state.saveConfig()
                closeWindow()
            },
            theme: state.themeStore.current
        )
        .onAppear { draftPrompt = state.config.changes.reviewRequestPrompt }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}
