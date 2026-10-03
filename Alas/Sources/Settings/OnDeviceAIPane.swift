import AppKit
import SwiftUI

struct OnDeviceAIPane: View {
    let state: AppState
    @Environment(\.theme) private var theme
    @State private var appleAvailability = LocalTextAppleAvailability.current()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("On-device AI").font(.system(size: 18, weight: .semibold))
                Text("Built-in helpers that run on this Mac.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.color("fg-dim"))
                    .padding(.bottom, 20)
                applePanel
                helpers
                LocalTextModelSettings(state: state)
                localOnlyFeatures
                Text("These built-in helpers process text on this Mac. Your coding agent is separate and follows its own provider settings. Generated text can be wrong; review it before acting.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.color("fg-dim"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .foregroundStyle(theme.color("fg"))
        .onAppear { appleAvailability = .current() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appleAvailability = .current()
        }
    }

    private var applePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Icon(name: "sparkles", size: 15, color: theme.color("accent"))
                Text("Apple Intelligence").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(appleStatus).font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.color(appleAvailability.isAvailable ? "add" : "fg-dim"))
            }
            Text(appleDetail).font(.system(size: 11.5))
                .foregroundStyle(theme.color("fg-dim"))
                .fixedSize(horizontal: false, vertical: true)
            if appleAvailability == .disabled || appleAvailability == .modelNotReady {
                Button("Open System Settings") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.color("accent"))
            }
        }
        .padding(14)
        .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color("line"), lineWidth: 0.5))
        .padding(.bottom, 20)
        .accessibilityElement(children: .contain)
    }

    private var appleStatus: String {
        switch appleAvailability {
        case .available: "Available"
        case .disabled: "Turned off"
        case .modelNotReady: "Preparing"
        case .unsupportedLocale: "Unavailable for this language"
        case .unsupportedOS, .deviceNotEligible, .unknown: "Unavailable"
        }
    }

    private var appleDetail: String {
        switch appleAvailability {
        case .available:
            "Used first for chat titles, worktree names, conflict explanations, and failure briefs. No additional model download is needed for these helpers."
        case .unsupportedOS:
            "Apple Intelligence requires macOS 26 or later. An allowed local model can still provide fallback on supported hardware."
        case .deviceNotEligible:
            "Apple Intelligence is not supported on this Mac. An allowed local model can provide fallback on supported hardware."
        case .disabled:
            "Enable Apple Intelligence in System Settings to use Apple's on-device model."
        case .modelNotReady:
            "Apple's model is not ready yet. Check Apple Intelligence in System Settings."
        case .unsupportedLocale:
            "Apple Intelligence does not support the current system language. An allowed local model can provide fallback."
        case .unknown:
            "Apple Intelligence is currently unavailable. An allowed local model can provide fallback."
        }
    }

    private var helpers: some View {
        SettingsGroup(title: "Helpers") {
            helperPreference("Chat titles", description: "Names chats when the coding agent doesn't provide a title.",
                selection: Binding(get: { state.config.harness.acpLocalTitlesEnabled },
                                   set: { state.setACPLocalTitlesEnabled($0) }))
            helperPreference("Worktree names", description: "Suggest a branch name from an attached issue.",
                selection: Binding(get: { state.config.issueWorktreeNameSuggestionsEnabled },
                                   set: { state.setIssueWorktreeNameSuggestionsEnabled($0) }))
            helperPreference("Failure briefs", description: "Explain failed run scripts and suggest checks.",
                selection: Binding(get: { state.config.runFailureBriefsEnabled },
                                   set: { state.setRunFailureBriefsEnabled($0) }))
            SettingsRow(name: "Conflict explanations", desc: "Explain a merge conflict when you request it.") {
                Text(appleAvailability.isAvailable || state.localTextModelAvailable ? "Available on request" : "No model available")
                    .font(.system(size: 12.5))
                providerNote
            }
            if let error = state.onDeviceAIHelperSettingsError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(theme.color("warn"))
                AlasButton(title: "Retry Save") { state.retryOnDeviceAIHelperSettings() }
            }
        }
        .padding(.bottom, 20)
    }

    private func helperPreference(_ name: String, description: String, selection: Binding<Bool>) -> some View {
        SettingsRow(name: name, desc: description) {
            AlasToggle(on: selection)
                .accessibilityLabel(name)
                .accessibilityValue(selection.wrappedValue ? "On" : "Off")
            providerNote
        }
    }

    private var providerNote: some View {
        Text(helperProviderDetail).font(.system(size: 10.5)).foregroundStyle(theme.color("fg-dim"))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var helperProviderDetail: String {
        if appleAvailability.isAvailable {
            return state.localTextModelAvailable
                ? "Apple Intelligence first · Local fallback ready" : "Apple Intelligence first"
        }
        return state.localTextModelAvailable ? "Using the local model" : "No model available"
    }

    private var localOnlyFeatures: some View {
        SettingsGroup(title: "Local-model features") {
            SettingsRow(name: "Session summaries", desc: "Summarize an idle chat to help you resume work.") {
                AlasToggle(on: Binding(
                    get: { state.config.sessionSummariesEnabled },
                    set: { enabled in Task {
                        if enabled { await state.enableSessionSummaries() }
                        else { await state.disableSessionSummaries() }
                    } }
                ))
                .disabled(!state.config.sessionSummariesEnabled && !state.localTextModelAvailable)
                .accessibilityLabel("Session summaries")
                .accessibilityValue(state.config.sessionSummariesEnabled ? "On" : "Off")
                Text(localFeatureDetail).font(.system(size: 10.5)).foregroundStyle(theme.color("fg-dim"))
                if let error = state.sessionSummarySettingsError {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(theme.color("warn"))
                    AlasButton(title: "Retry Save") { Task { await state.retrySessionSummarySettings() } }
                        .disabled(state.localTextRemovalInProgress)
                } else if state.config.sessionSummariesEnabled && state.localTextModelAvailable && !state.sessionSummariesRuntimeEnabled {
                    Text("Summaries are paused. Retry to resume.")
                        .font(.system(size: 11.5)).foregroundStyle(theme.color("warn"))
                    AlasButton(title: "Retry Inference") { Task { await state.retrySessionSummarySettings() } }
                }
            }
            SettingsRow(name: "Next-prompt suggestions", desc: "Suggest an optional follow-up after a successful agent turn. Tab inserts it for review; it never sends automatically.") {
                AlasToggle(on: Binding(
                    get: { state.config.nextPromptSuggestionsEnabled },
                    set: { enabled in Task {
                        if enabled { await state.enableNextPromptSuggestions() }
                        else { await state.disableNextPromptSuggestions() }
                    } }
                ))
                .disabled(!state.config.nextPromptSuggestionsEnabled && !state.localTextModelAvailable)
                .accessibilityLabel("Next-prompt suggestions")
                .accessibilityValue(state.config.nextPromptSuggestionsEnabled ? "On" : "Off")
                Text(localFeatureDetail).font(.system(size: 10.5)).foregroundStyle(theme.color("fg-dim"))
                if let error = state.nextPromptSettingsError {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(theme.color("warn"))
                    AlasButton(title: "Retry Save") { Task { await state.retryNextPromptSuggestions() } }
                        .disabled(state.localTextRemovalInProgress)
                } else if state.config.nextPromptSuggestionsEnabled && state.localTextModelAvailable {
                    if state.nextPromptInferenceState == .retryRequired || !state.nextPromptRuntimeEnabled {
                        Text("Suggestions are paused. Retry to resume.")
                            .font(.system(size: 11.5)).foregroundStyle(theme.color("warn"))
                        AlasButton(title: "Retry Inference") { Task { await state.retryNextPromptSuggestions() } }
                    } else if state.nextPromptInferenceState == .failed {
                        Text("The last suggestion failed. We'll retry after the next reply.")
                            .font(.system(size: 11.5)).foregroundStyle(theme.color("fg-dim"))
                    }
                }
            }
        }
    }

    private var localFeatureDetail: String {
        if state.localTextModelAvailable { return "Runs locally on this Mac" }
        if state.localTextModelDisableSavePending {
            return "Paused until the model permission change is saved"
        }
        switch state.localTextModelState {
        case .downloading, .verifying: return "Available after verification"
        case .ready:
            return state.localTextSupported ? "Turn on Use local model" : "Requires Apple silicon with a supported Metal GPU"
        default: return "Requires the local model"
        }
    }
}
