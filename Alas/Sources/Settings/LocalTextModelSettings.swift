import SwiftUI

struct LocalTextModelSettings: View {
    let state: AppState
    @Environment(\.theme) private var theme
    @State private var showingDownloadConsent = false
    @State private var showingRemovalConfirmation = false
    private static let manifest = try? LocalTextModelManifest.bundled()
    private static let downloadSize = manifest.map {
        ByteCountFormatter.string(fromByteCount: $0.totalBytes, countStyle: .file)
    } ?? "Size unavailable"

    var body: some View {
        SettingsGroup(title: "Local model") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Icon(name: "cpu", size: 20, color: theme.color("fg-muted"))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Qwen3").font(.system(size: 12.5, weight: .semibold))
                        Text("4B parameters · 4-bit · \(Self.downloadSize)")
                            .font(.system(size: 10.5)).foregroundStyle(theme.color("fg-dim"))
                    }
                    Spacer()
                    Text(modelStatus).font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.color(state.localTextModelAvailable ? "add" : "fg-dim"))
                }
                Text("Optional download").font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.color("fg-dim"))
                Text("Required for session summaries and next-prompt suggestions, and provides fallback for the other built-in helpers when applicable. Feature preferences remain separate.")
                    .font(.system(size: 11.5)).foregroundStyle(theme.color("fg-dim"))
                    .fixedSize(horizontal: false, vertical: true)
                modelActions
                if !state.localTextSupported {
                    Text("Local inference requires Apple silicon with a supported Metal GPU. You can still remove existing model files.")
                        .font(.system(size: 11.5)).foregroundStyle(theme.color("fg-dim"))
                }
                if let error = state.localTextModelSettingsError {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(theme.color("warn"))
                    if state.localTextModelDisableSavePending {
                        AlasButton(title: "Retry Save") { Task { await state.retryLocalTextModelSettings() } }
                            .disabled(state.localTextRemovalInProgress || state.localTextModelPermissionChangeInProgress)
                    }
                }
                if let failure = state.localTextRemovalFailure {
                    Text(failure.settingsMessage).font(.system(size: 11.5)).foregroundStyle(theme.color("warn"))
                    AlasButton(title: "Retry Removal") { Task { await state.removeLocalTextModel() } }
                        .disabled(!state.canRemoveLocalTextModel)
                }
            }
            .padding(14)
            .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color("line"), lineWidth: 0.5))
            Text("Local inference can use several GB of memory. Some process memory may remain allocated after the model unloads.")
                .font(.system(size: 11.5)).foregroundStyle(theme.color("fg-dim"))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.bottom, 20)
        .task { await state.inspectLocalTextModelOnSettingsAppearance() }
        .alert("Download the local model?", isPresented: $showingDownloadConsent) {
            Button("Download and Allow") { Task { await state.downloadLocalTextModel() } }
                .disabled(downloadDisabled)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloads \(Self.downloadSize) of model files from Hugging Face. Inference runs on this Mac and can use several GB of memory; some process memory may remain allocated after unloading. Downloading allows built-in helpers to use this model. Session summaries and next-prompt suggestions remain separate preferences and are not turned on by the download.")
        }
        .alert("Remove the local model?", isPresented: $showingRemovalConfirmation) {
            Button("Remove Model", role: .destructive) { Task { await state.removeLocalTextModel() } }
                .disabled(!state.canRemoveLocalTextModel)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes up to \(Self.downloadSize) of shared model files and turns off local model use. Session summaries, next-prompt suggestions, and local fallback will be unavailable until you download and allow the model again. Feature preferences stay unchanged. Available Apple Intelligence helpers keep working.")
        }
    }

    private var modelStatus: String {
        if state.localTextRemovalInProgress { return "Removing…" }
        switch state.localTextModelState {
        case .notInstalled: return "Not installed"
        case .downloading: return "Downloading"
        case .verifying: return "Verifying"
        case .ready: return state.localTextModelAvailable ? "Ready" : "Installed"
        case .failed: return "Needs attention"
        case .unavailable: return "Unavailable"
        }
    }

    @ViewBuilder private var modelActions: some View {
        switch state.localTextModelState {
        case .unavailable:
            Text("The bundled model manifest is unavailable. Reinstall Alas to restore it.")
                .font(.system(size: 11.5)).foregroundStyle(theme.color("warn"))
        case .notInstalled:
            AlasButton(title: "Download…") { showingDownloadConsent = true }
                .disabled(downloadDisabled)
        case .downloading(let received, let expected):
            Text("Available Apple Intelligence helpers keep working while the model downloads.")
                .font(.system(size: 11.5)).foregroundStyle(theme.color("fg-dim"))
            ProgressView(value: Double(received), total: Double(max(expected, 1)))
                .accessibilityLabel("Model download")
                .accessibilityValue("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
                    .font(.system(size: 10.5)).foregroundStyle(theme.color("fg-dim"))
                Spacer()
                AlasButton(title: "Cancel", style: .subtle) { Task { await state.cancelLocalTextDownload() } }
                    .disabled(state.localTextRemovalInProgress || state.localTextModelPermissionChangeInProgress)
            }
        case .verifying:
            HStack {
                ProgressView().controlSize(.small).accessibilityLabel("Verifying model files")
                Text("Verifying model files…").font(.system(size: 11.5)).foregroundStyle(theme.color("fg-dim"))
                Spacer()
                AlasButton(title: "Cancel", style: .subtle) { Task { await state.cancelLocalTextDownload() } }
                    .disabled(state.localTextRemovalInProgress || state.localTextModelPermissionChangeInProgress)
            }
        case .ready:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use local model").font(.system(size: 12.5, weight: .medium))
                    Text("Allow these helpers to use the installed model.")
                        .font(.system(size: 11.5)).foregroundStyle(theme.color("fg-dim"))
                }
                Spacer()
                AlasToggle(on: Binding(
                    get: { state.config.localTextModelEnabled },
                    set: { enabled in Task { await state.setLocalTextModelEnabled(enabled) } }
                ))
                .disabled(!state.localTextSupported || state.localTextRemovalInProgress || state.localTextModelPermissionChangeInProgress)
                .accessibilityLabel("Use local model")
                .accessibilityValue(state.localTextModelDisableSavePending ? "Off for this session; not saved" : state.config.localTextModelEnabled ? "On" : "Off")
            }
            AlasButton(title: "Remove…", style: .subtle) { showingRemovalConfirmation = true }
                .disabled(!state.canRemoveLocalTextModel)
        case .failed(let failure):
            Text(failure.settingsMessage).font(.system(size: 11.5)).foregroundStyle(theme.color("warn"))
            HStack {
                AlasButton(title: "Retry Download…") { showingDownloadConsent = true }
                    .disabled(downloadDisabled)
                AlasButton(title: "Remove…", style: .subtle) { showingRemovalConfirmation = true }
                    .disabled(!state.canRemoveLocalTextModel)
            }
        }
    }

    private var downloadDisabled: Bool {
        !state.localTextSupported || state.localTextRemovalInProgress
            || state.localTextModelPermissionChangeInProgress || state.localTextModelDisableSavePending
            || Self.manifest == nil
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
