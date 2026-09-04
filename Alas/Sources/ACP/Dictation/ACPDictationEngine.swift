import Foundation

/// Callbacks a dictation engine reports through. Grouped into one value so
/// `start` keeps a readable signature as the engine grew a preferred
/// locale and a silence report.
struct ACPDictationCallbacks {
    /// Setup finished and audio is being captured.
    let onReady: () -> Void
    /// A transcript update. Volatile updates repeat as the utterance is
    /// corrected; each utterance ends with exactly one final update.
    let onResult: (_ text: String, _ isFinal: Bool) -> Void
    /// Setup or transcription failed; dictation is over.
    let onFailure: (_ message: String) -> Void
    /// Audio is flowing but every sample so far has been silence, which
    /// almost always means the wrong input device is selected. Reported at
    /// most once per session, and does NOT stop dictation, since sound may
    /// still start. Carries the input device name when it's known.
    let onSilence: (_ deviceName: String?) -> Void
}

/// Seam between `ACPDictationService` (the state machine) and whatever
/// actually captures audio and transcribes it. Isolating this behind a
/// protocol lets the state machine be tested without a microphone or the
/// Speech framework.
@MainActor
protocol ACPDictationEngine: AnyObject {
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
    /// or nil to detect one automatically.
    func start(preferredLocaleIdentifier: String?, callbacks: ACPDictationCallbacks)

    /// Tears down the audio tap and transcriber. Safe to call even if
    /// `start` never reached `onReady`.
    func stop()
}
