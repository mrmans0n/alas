import SwiftUI

struct LocalTextModelSettings: View {
    static let nextPromptConsent = "Downloads about 2.3 GB of model files. Local inference can use several GB of memory, and process memory may remain elevated after unloading. Recent chat text is processed on this Mac; it is not sent to a suggestion service. Suggestions may be wrong or absent. Tab inserts a suggestion for review and never sends it automatically."
    static let sessionSummaryConsent = "Downloads roughly 2.3 GB of model files. Session transcripts are processed locally on this Mac. Inference can use multi-gigabyte memory, and process memory may remain retained after unloading. Summaries may be incomplete or wrong and should be reviewed before acting."

    static func sessionSummaryReadyDetail(
        requested: Bool,
        runtimeEnabled: Bool,
        disableSavePending: Bool
    ) -> String? {
        if disableSavePending {
            return "Model installed. Session summaries are off for this session."
        }
        if runtimeEnabled {
            return "Model ready. Session summaries run locally."
        }
        return requested ? "Model installed. Retry to resume session summaries." : nil
    }

    let state: AppState
    @State private var showingNextPromptConsent = false
    @State private var showingSummaryConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            nextPromptRow
            sessionSummaryRow
            if !state.localTextSupported {
                Text("Requires Apple silicon with a supported Metal GPU. On-device text features are unavailable on this Mac.")
            } else {
                modelStatus
            }
            if let failure = state.localTextRemovalFailure {
                Text(failure == .inUse
                     ? "Model in use by another Alas process. Close its on-device features and retry removal."
                     : failure.settingsMessage)
                Button("Retry Removal") { Task { await state.removeLocalTextModel() } }
                    .disabled(state.localTextRemovalInProgress)
            } else if state.localTextModelState == .ready {
                Button("Remove Model", role: .destructive) { Task { await state.removeLocalTextModel() } }
                    .disabled(!state.canRemoveLocalTextModel)
                    .help(state.localTextRemovalInProgress
                          ? "Model removal is in progress."
                          : state.canRemoveLocalTextModel
                              ? "Remove the shared on-device model."
                              : "Disable both on-device capabilities before removing the model.")
            }
        }
        .font(.callout)
        .task { await state.inspectLocalTextModelOnSettingsAppearance() }
        .alert("Enable experimental next-prompt suggestions?", isPresented: $showingNextPromptConsent) {
            Button("Enable and Install") { Task { await state.enableNextPromptSuggestions() } }
                .disabled(state.localTextRemovalInProgress)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.nextPromptConsent)
        }
        .alert("Enable experimental session summaries?", isPresented: $showingSummaryConsent) {
            Button("Enable and Install") { Task { await state.enableSessionSummaries() } }
                .disabled(state.localTextRemovalInProgress)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.sessionSummaryConsent)
        }
    }

    private var nextPromptRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(name: "Next-prompt suggestions", desc: "Experimental, on-device suggestions after a successful agent turn.") {
                if state.nextPromptDisableSavePending {
                    Button("Retry Disable") { Task { await state.retryNextPromptSuggestions() } }
                        .disabled(state.localTextRemovalInProgress)
                } else if state.config.nextPromptSuggestionsEnabled {
                    Button("Disable") { Task { await state.disableNextPromptSuggestions() } }
                } else {
                    Button("Enable…") { showingNextPromptConsent = true }
                        .disabled(!state.localTextSupported || state.localTextRemovalInProgress)
                }
            }
            if state.nextPromptDisableSavePending {
                Text("Suggestions are off for this session. Disabling has not been saved.")
            }
            if let error = state.nextPromptSettingsError { Text(error).foregroundStyle(.red) }
        }
    }

    private var sessionSummaryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(name: "Session summaries", desc: "Experimental, on-device summaries for resuming an idle session.") {
                if state.sessionSummaryDisableSavePending {
                    Button("Retry Disable") { Task { await state.retrySessionSummarySettings() } }
                        .disabled(state.localTextRemovalInProgress)
                } else if state.config.sessionSummariesEnabled {
                    Button("Disable") { Task { await state.disableSessionSummaries() } }
                } else {
                    Button("Enable…") { showingSummaryConsent = true }
                        .disabled(!state.localTextSupported || state.localTextRemovalInProgress)
                }
            }
            if state.sessionSummaryDisableSavePending {
                Text("Summaries are off for this session. Disabling has not been saved.")
            }
            if let error = state.sessionSummarySettingsError { Text(error).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var modelStatus: some View {
        switch state.localTextModelState {
        case .unavailable:
            Text("The bundled model manifest is unavailable. Reinstall Alas to restore it.")
        case .notInstalled:
            Text("Model not installed.")
            if state.config.nextPromptSuggestionsEnabled || state.config.sessionSummariesEnabled { retryButton }
        case .downloading(let received, let expected):
            ProgressView(value: Double(received), total: Double(max(expected, 1)))
                .accessibilityLabel("Downloading on-device model")
            Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
            Button("Cancel Download") { Task { await state.cancelLocalTextDownload() } }
        case .verifying:
            ProgressView("Verifying model…")
        case .ready:
            if state.config.nextPromptSuggestionsEnabled {
                if state.nextPromptInferenceState == .failed && state.nextPromptRuntimeEnabled {
                    Text("The last suggestion failed. We'll try again after the next assistant reply.")
                    retryButton
                } else if state.nextPromptInferenceState == .retryRequired ||
                            state.nextPromptInferenceState == .failed {
                    Text("Local inference paused after a failure. Retry to use suggestions again.")
                    retryButton
                } else if !state.nextPromptRuntimeEnabled {
                    Text("Model installed. Retry to resume suggestions.")
                    retryButton
                } else {
                    Text("Model ready. Suggestions run locally.")
                }
            } else if let detail = Self.sessionSummaryReadyDetail(
                requested: state.config.sessionSummariesEnabled,
                runtimeEnabled: state.sessionSummariesRuntimeEnabled,
                disableSavePending: state.sessionSummaryDisableSavePending
            ) {
                Text(detail)
                if state.config.sessionSummariesEnabled && !state.sessionSummariesRuntimeEnabled &&
                    !state.sessionSummaryDisableSavePending {
                    retryButton
                }
            } else {
                Text("Model installed. On-device features disabled.")
            }
        case .failed(let failure):
            Text(failure.settingsMessage)
            if state.config.nextPromptSuggestionsEnabled || state.config.sessionSummariesEnabled { retryButton }
        }
    }

    private var retryButton: some View {
        Button("Retry") { Task { await state.retryLocalTextModel() } }
            .disabled(state.localTextRemovalInProgress)
    }
}

extension LocalTextModelFailure {
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
