import Foundation

extension AppState {
    /// Captions borrow the local model consent commit message drafts use: Apple Intelligence when
    /// the system offers it, else the downloaded model under next-prompt suggestions or session summaries.
    /// Saved captions show whenever the setting is on, with or without a model.
    func makeTurnCaptionStore() -> ACPTurnCaptionStore {
        ACPTurnCaptionStore(
            isEnabled: { [weak self] in self?.config.turnCaptionsEnabled ?? false },
            canGenerate: { [weak self] in
                LocalTextAppleIntelligence.isAvailable || self?.commitMessageMLXSuggestionsAvailable == true
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
            },
            load: { [weak self] sessionId in
                guard let persistence = self?.acpManager(forSession: sessionId)?.persistence else { return [] }
                return (try? await persistence.loadTurnCaptions(sessionId: sessionId)) ?? []
            },
            save: { [weak self] sessionId, caption in
                guard let persistence = self?.acpManager(forSession: sessionId)?.persistence else { return }
                try? await persistence.saveTurnCaption(sessionId: sessionId, caption)
            }
        )
    }

    /// Captions the turn `sessionID` just finished, so it is saved before its card shows here or on a
    /// Remote client. Turns without a card ask for nothing.
    func captionFinishedTurn(_ completion: ACPTurnCompletion) {
        guard completion.result == .completed else { return }
        let sessionID = completion.sessionId
        guard let manager = acpManager(forSession: sessionID), let session = manager.sessions[sessionID] else { return }
        let messages = session.transcript.messages
        let offset = session.transcript.messageIndexOffset
        let worktreeRoot = manager.worktreePath
        guard let answerIndex = messages.lastIndex(where: { if case .agent = $0 { true } else { false } }),
              let changes = ACPTurnChanges.forAnswer(
                  at: answerIndex, in: messages, isTurnActive: false, worktreeRoot: worktreeRoot)
        else { return }
        turnCaptions.request(key: .init(sessionId: sessionID, answerIndex: offset + answerIndex, digest: changes.digest)) {
            changes.captionInput(messages: messages, answerIndex: answerIndex, worktreeRoot: worktreeRoot)
        }
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
