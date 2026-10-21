import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Drives the composer's push-to-talk dictation button. Owns no audio or
/// speech APIs itself — `engine` does the actual work — so this class is
/// just the state machine: idle → preparing → listening, with `failed`
/// surfacing engine errors and `unavailable` hiding the control entirely.
@MainActor
public final class ACPDictationService: ChangeTracking {
    nonisolated(unsafe) public let willChange = ChangeSignal<Void>()
    @Tracked public private(set) var state: ACPDictationState

    /// Fires for every transcript update while listening — volatile
    /// updates (not yet final) may repeat as the utterance is corrected,
    /// followed by exactly one final update per utterance.
    public var onTranscriptUpdate: ((_ text: String, _ isFinal: Bool) -> Void)?
    /// Fires whenever listening ends, for any reason (manual stop or
    /// engine failure) — used to stop tracking the in-progress dictation
    /// span without touching already-committed text.
    public var onStop: (() -> Void)?
    /// Fires with a human-readable warning that doesn't end dictation, so
    /// the composer can surface it in its notice line.
    public var onNotice: ((String) -> Void)?

    /// The user's language and microphone choices, read when a session starts.
    public var preferences = ACPDictationPreferences()

    private let engine: ACPDictationEngine
    /// When the press that started the current session went down, while
    /// its release is still pending. Nil when the session started any other
    /// way, so a release never stops a session it didn't start.
    private var shortcutPressedAt: TimeInterval?

    /// A shortcut press held at least this long is push-to-talk: dictation
    /// stops on release. A shorter tap leaves it running until the next tap.
    public nonisolated static let shortcutHoldThreshold: TimeInterval = 0.3

    public init(engine: ACPDictationEngine) {
        self.engine = engine
        self.state = engine.isAvailable ? .idle : .unavailable
    }

    /// Languages ready to transcribe without a model download.
    public func installedLocaleIdentifiers() async -> [String] {
        await engine.installedLocaleIdentifiers()
    }

    public func toggle() {
        switch state {
        case .idle, .failed:
            start()
        case .preparing, .listening:
            stop()
        case .unavailable:
            break
        }
    }

    /// Tap-or-hold handling for the Dictate shortcut. Times are the key
    /// events' timestamps. A press while dictating stops it; otherwise it
    /// starts, and the release stops it again if the key was held at least
    /// `shortcutHoldThreshold`.
    public func handleShortcut(_ event: ACPDictationShortcutEvent) {
        switch event {
        case .pressed(let time):
            switch state {
            case .preparing, .listening:
                stop()
            case .idle, .failed:
                start()
                shortcutPressedAt = state == .preparing ? time : nil
            case .unavailable:
                break
            }
        case .released(let time):
            guard let pressedAt = shortcutPressedAt else { return }
            shortcutPressedAt = nil
            if time - pressedAt >= Self.shortcutHoldThreshold { stop() }
        }
    }

    public func start() {
        guard state == .idle || isFailed else { return }
        state = .preparing
        let locale = preferences.localeIdentifier
        let microphone = preferences.microphone
        engine.start(
            preferredLocaleIdentifier: locale.isEmpty ? nil : locale,
            microphoneUID: microphone?.uid,
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
                },
                onMicrophoneUnavailable: { [weak self] in
                    guard let self, self.state == .preparing || self.state == .listening,
                          let microphone else { return }
                    self.onNotice?("“\(microphone.name)” isn't connected. Using the system default microphone.")
                }
            )
        )
    }

    /// Wording for the "we're hearing nothing" warning. Naming the device
    /// matters: the usual cause is a virtual input (conferencing or VR
    /// software) sitting in front of the real microphone, and the fix is in
    /// the Sound settings rather than in this app.
    public nonisolated static func silenceMessage(deviceName: String?) -> String {
        guard let deviceName, !deviceName.isEmpty else {
            return "No audio from the microphone. Check Sound settings."
        }
        return "No audio from “\(deviceName)”. Check Sound settings."
    }

    public func stop() {
        // Any stop ends the session a pending shortcut release refers to.
        shortcutPressedAt = nil
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

/// A press or release of the Dictate shortcut, timestamped by its key event.
public enum ACPDictationShortcutEvent: Equatable, Sendable {
    case pressed(at: TimeInterval)
    case released(at: TimeInterval)
}
