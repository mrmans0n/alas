import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Callbacks a dictation engine reports through. Grouped into one value so
/// `start` keeps a readable signature as the engine grew a preferred
/// locale, a chosen microphone and a silence report.
public struct ACPDictationCallbacks {
    /// Setup finished and audio is being captured.
    public let onReady: () -> Void
    /// A transcript update. Volatile updates repeat as the utterance is
    /// corrected; each utterance ends with exactly one final update.
    public let onResult: (_ text: String, _ isFinal: Bool) -> Void
    /// Setup or transcription failed; dictation is over.
    public let onFailure: (_ message: String) -> Void
    /// Audio is flowing but every sample so far has been silence, which
    /// almost always means the wrong input device is selected. Reported at
    /// most once per session, and does NOT stop dictation, since sound may
    /// still start. Carries the input device name when it's known.
    public let onSilence: (_ deviceName: String?) -> Void
    /// The chosen microphone isn't connected, so recording fell back to the
    /// system default input. Does not stop dictation.
    public let onMicrophoneUnavailable: () -> Void

    public init(
        onReady: @escaping () -> Void,
        onResult: @escaping (_ text: String, _ isFinal: Bool) -> Void,
        onFailure: @escaping (_ message: String) -> Void,
        onSilence: @escaping (_ deviceName: String?) -> Void,
        onMicrophoneUnavailable: @escaping () -> Void
    ) {
        self.onReady = onReady
        self.onResult = onResult
        self.onFailure = onFailure
        self.onSilence = onSilence
        self.onMicrophoneUnavailable = onMicrophoneUnavailable
    }
}

/// Seam between `ACPDictationService` (the state machine) and whatever
/// actually captures audio and transcribes it. Isolating this behind a
/// protocol lets the state machine be tested without a microphone or the
/// Speech framework.
@MainActor
public protocol ACPDictationEngine: AnyObject {
    /// False when this OS has no speech-to-text engine available — the
    /// service starts `.unavailable` and `start()` is a no-op.
    var isAvailable: Bool { get }

    /// Locale identifiers whose assets are already downloaded, so picking
    /// one starts transcribing without waiting on a model download.
    func installedLocaleIdentifiers() async -> [String]

    /// Requests permissions, prepares the transcriber, and begins
    /// streaming microphone audio into it. Exactly one of `onReady` or
    /// `onFailure` fires once setup resolves; `onResult` may then fire any
    /// number of times until `stop()` is called.
    ///
    /// `preferredLocaleIdentifier` is the user's explicit language choice,
    /// or nil to detect one automatically. `microphoneUID` is the CoreAudio
    /// UID of the input to record from, or nil for the system default.
    func start(preferredLocaleIdentifier: String?, microphoneUID: String?, callbacks: ACPDictationCallbacks)

    /// Tears down the audio tap and transcriber. Safe to call even if
    /// `start` never reached `onReady`.
    func stop()
}
