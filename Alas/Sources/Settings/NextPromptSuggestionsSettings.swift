import SwiftUI

struct NextPromptSuggestionsSettings: View {
    let state: AppState
    @State private var showingConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(name: "Next-prompt suggestions", desc: "Experimental, on-device suggestions after a successful agent turn.") {
                if state.config.nextPromptSuggestionsEnabled {
                    Button("Disable") { Task { await state.disableNextPromptSuggestions() } }
                } else {
                    Button("Enable…") { showingConsent = true }
                        .disabled(!state.nextPromptSupported)
                }
            }
            if !state.nextPromptSupported {
                Text("Requires Apple silicon with a supported Metal GPU. Suggestions are unavailable on this Mac.")
            } else {
                modelStatus
            }
            if let error = state.nextPromptSettingsError { Text(error).foregroundStyle(.red) }
            if let failure = state.nextPromptRemovalFailure {
                Text(failure == .inUse ? "Model in use by another Alas process. Close its suggestions and retry removal." : failure.settingsMessage)
                Button("Retry Removal") { Task { await state.removeNextPromptModel() } }
            } else if !state.config.nextPromptSuggestionsEnabled, state.nextPromptModelState == .ready {
                Button("Remove Model", role: .destructive) { Task { await state.removeNextPromptModel() } }
            }
        }
        .font(.callout)
        .alert("Enable experimental next-prompt suggestions?", isPresented: $showingConsent) {
            Button("Enable and Install") { Task { await state.enableNextPromptSuggestions() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloads about 2.3 GB of model files. Local inference can use several GB of memory, and process memory may remain elevated after unloading. Recent chat text is processed on this Mac; it is not sent to a suggestion service. Suggestions may be wrong or absent. Tab inserts a suggestion for review and never sends it automatically.")
        }
    }

    @ViewBuilder private var modelStatus: some View {
        switch state.nextPromptModelState {
        case .unavailable:
            Text("The bundled model manifest is unavailable. Reinstall Alas to restore it.")
        case .notInstalled:
            Text(state.config.nextPromptSuggestionsEnabled ? "Enabled, model not installed. Retry to install." : "Model not installed.")
            if state.config.nextPromptSuggestionsEnabled { retryButton }
        case .downloading(let received, let expected):
            ProgressView(value: Double(received), total: Double(max(expected, 1)))
                .accessibilityLabel("Downloading next-prompt model")
            Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
            Button("Cancel Download") { Task { await state.cancelNextPromptDownload() } }
        case .verifying:
            ProgressView("Verifying model…")
        case .ready:
            if state.nextPromptInferenceState == .retryRequired || state.nextPromptInferenceState == .failed {
                Text("Local inference paused after a failure. Retry to use suggestions again.")
                if state.config.nextPromptSuggestionsEnabled { retryButton }
            } else if state.config.nextPromptSuggestionsEnabled && !state.nextPromptRuntimeEnabled {
                Text("Model installed. Retry to resume suggestions.")
                retryButton
            } else {
                Text(state.config.nextPromptSuggestionsEnabled ? "Model ready. Suggestions run locally." : "Model installed. Suggestions disabled.")
            }
        case .failed(let failure):
            Text(failure.settingsMessage)
            if state.config.nextPromptSuggestionsEnabled { retryButton }
        }
    }

    private var retryButton: some View {
        Button("Retry") { Task { await state.retryNextPromptSuggestions() } }
    }
}

extension NextPromptModelFailure {
    var settingsMessage: String {
        switch self {
        case .busy: "A model operation is already in progress. Retry when it finishes."
        case .inUse: "The model is in use by another Alas process. Retry after it releases the model."
        case .network: "The model download failed. Check your connection and retry."
        case .insufficientSpace: "There is not enough disk space for the model."
        case .integrity: "Model verification failed. Retry to replace the incomplete files."
        case .invalidManifest: "The bundled model manifest is invalid. Reinstall Alas."
        case .invalidPath: "The model directory is unsafe or inaccessible."
        case .filesystem: "The model files could not be read or written. Check available disk space and permissions."
        }
    }
}
