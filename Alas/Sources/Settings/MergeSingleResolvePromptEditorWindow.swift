import SwiftUI

struct MergeSingleResolvePromptEditorWindow: View {
    @Bindable var state: AppState
    @State private var draftPrompt = ""

    var body: some View {
        PromptEditorBody(
            windowTitle: "Merge: Single-File Prompt",
            title: "Per-file merge-conflict resolution prompt",
            description: "Used by 'Ask agent to resolve' in the merge editor toolbar. The three sides (LOCAL / BASE / REMOTE / MERGED) are appended automatically. Placeholders: {filePath}, {language}.",
            draftPrompt: $draftPrompt,
            onReset: { draftPrompt = AppConfig.defaultMergeSingleResolvePrompt },
            onCancel: { closeWindow() },
            onSave: {
                state.config.changes.mergeSingleResolvePrompt = draftPrompt
                state.saveConfig()
                closeWindow()
            },
            theme: state.themeStore.current
        )
        .onAppear { draftPrompt = state.config.changes.mergeSingleResolvePrompt }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}
