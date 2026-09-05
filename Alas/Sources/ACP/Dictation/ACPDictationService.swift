import Foundation

/// Drives the composer's push-to-talk dictation button. Owns no audio or
/// speech APIs itself — `engine` does the actual work — so this class is
/// just the state machine: idle → preparing → listening, with `failed`
/// surfacing engine errors and `unavailable` hiding the control entirely.
@MainActor
final class ACPDictationService: ObservableObject {
    @Published private(set) var state: ACPDictationState

    /// Fires for every transcript update while listening — volatile
    /// updates (not yet final) may repeat as the utterance is corrected,
    /// followed by exactly one final update per utterance.
    var onTranscriptUpdate: ((_ text: String, _ isFinal: Bool) -> Void)?
    /// Fires whenever listening ends, for any reason (manual stop or
    /// engine failure) — used to stop tracking the in-progress dictation
    /// span without touching already-committed text.
    var onStop: (() -> Void)?
    /// Fires with a human-readable warning that doesn't end dictation, so
    /// the composer can surface it in its notice line.
    var onNotice: ((String) -> Void)?

    /// The user's explicit language choice. Empty means automatic.
    var preferredLocaleIdentifier: String = ACPDictationLocaleFormatter.automaticIdentifier

    private let engine: ACPDictationEngine

    init(engine: ACPDictationEngine) {
        self.engine = engine
        self.state = engine.isAvailable ? .idle : .unavailable
    }

    /// Languages ready to transcribe without a model download.
    func installedLocaleIdentifiers() async -> [String] {
        await engine.installedLocaleIdentifiers()
    }

    func toggle() {
        switch state {
        case .idle, .failed:
            start()
        case .preparing, .listening:
            stop()
        case .unavailable:
            break
        }
    }

    func start() {
        guard state == .idle || isFailed else { return }
        state = .preparing
        let preferred = preferredLocaleIdentifier.isEmpty ? nil : preferredLocaleIdentifier
        engine.start(
            preferredLocaleIdentifier: preferred,
            callbacks: ACPDictationCallbacks(
                onReady: { [weak self] in
                    guard let self, self.state == .preparing else { return }
                    self.state = .listening
                },
                onResult: { [weak self] text, isFinal in
                    guard let self, self.state == .listening else { return }
                    self.onTranscriptUpdate?(text, isFinal)
                },
                onFailure: { [weak self] message in
                    guard let self else { return }
                    self.state = .failed(message)
                    self.onStop?()
                },
                onSilence: { [weak self] deviceName in
                    guard let self, self.state == .listening else { return }
                    self.onNotice?(Self.silenceMessage(deviceName: deviceName))
                }
            )
        )
    }

    /// Wording for the "we're hearing nothing" warning. Naming the device
    /// matters: the usual cause is a virtual input (conferencing or VR
    /// software) sitting in front of the real microphone, and the fix is in
    /// the Sound settings rather than in this app.
    nonisolated static func silenceMessage(deviceName: String?) -> String {
        guard let deviceName, !deviceName.isEmpty else {
            return "No audio from the microphone. Check Sound settings."
        }
        return "No audio from “\(deviceName)”. Check Sound settings."
    }

    func stop() {
        guard state == .preparing || state == .listening else { return }
        engine.stop()
        state = .idle
        onStop?()
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}
