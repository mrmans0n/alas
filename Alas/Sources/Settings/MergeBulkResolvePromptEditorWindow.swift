import SwiftUI

struct MergeBulkResolvePromptEditorWindow: View {
    @Bindable var state: AppState
    @State private var draftPrompt = ""

    var body: some View {
        PromptEditorBody(
            windowTitle: "Merge: Resolve All Prompt",
            title: "Bulk merge-conflict resolution prompt",
            description: "Sent to the agent CWD'd at the worktree when the user clicks 'Resolve all with agent' in the Conflicts section. The agent uses its own tools to enumerate, reconcile, and stage every conflicted file.",
            draftPrompt: $draftPrompt,
            onReset: { draftPrompt = AppConfig.defaultMergeBulkResolvePrompt },
            onCancel: { closeWindow() },
            onSave: {
                state.config.changes.mergeBulkResolvePrompt = draftPrompt
                state.saveConfig()
                closeWindow()
            },
            theme: state.themeStore.current
        )
        .onAppear { draftPrompt = state.config.changes.mergeBulkResolvePrompt }
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}
