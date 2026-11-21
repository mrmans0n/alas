import Foundation

extension AppState {
    /// Captions borrow the local model consent commit message drafts use: Apple Intelligence when
    /// the system offers it, else the downloaded model under next-prompt suggestions or session summaries.
    func makeTurnCaptionStore() -> ACPTurnCaptionStore {
        ACPTurnCaptionStore(
            isEnabled: { [weak self] in
                guard let self else { return false }
                return self.config.turnCaptionsEnabled
                    && (LocalTextAppleIntelligence.isAvailable || self.commitMessageMLXSuggestionsAvailable)
            },
            generate: { [weak self] input in
                guard let self else { return nil }
                let router = LocalTextAppleFirstRouter(
                    engine: self.localTextInference,
                    isAppleIntelligenceAvailable: { LocalTextAppleIntelligence.isAvailable },
                    generateWithAppleIntelligence: { request in await LocalTextAppleIntelligence.generate(request) },
                    isMLXAvailable: { [weak self] in self?.commitMessageMLXSuggestionsAvailable ?? false }
                )
                let request = LocalTextGenerationRequest(
                    messageCandidates: ACPTurnCaptionPolicy.messageCandidates(for: input),
                    inputTokenLimit: ACPTurnCaptionPolicy.inputTokenLimit,
                    maxTokens: ACPTurnCaptionPolicy.maxTokens,
                    temperature: 0,
                    prefillStepSize: 512,
                    timeout: ACPTurnCaptionPolicy.timeout
                )
                return await router.generate(request, caller: .turnCaption, priority: .background) {
                    ACPTurnCaptionPolicy.parse($0)
                }
            }
        )
    }

    func setTurnCaptionsEnabled(_ enabled: Bool) {
        let previous = config.turnCaptionsEnabled
        config.turnCaptionsEnabled = enabled
        if saveConfig() {
            onDeviceAIHelperSettingsError = nil
        } else {
            if enabled { config.turnCaptionsEnabled = previous }
            onDeviceAIHelperSettingsError =
                "Could not save helper settings. Changes apply only to this session. Retry before quitting."
        }
        if !enabled { turnCaptions.reset() }
    }
}
