import Foundation
import AlasModel

/// The user's dictation choices, passed to composers as one value so a new
/// choice doesn't add another parameter to every layer between Settings and
/// the mic button.
public struct ACPDictationPreferences: Equatable, Sendable {
    /// Locale identifier; empty means detect automatically.
    public var localeIdentifier: String
    /// Nil means the system's default input device.
    public var microphone: DictationMicrophone?

    public init(
        localeIdentifier: String = ACPDictationLocaleFormatter.automaticIdentifier,
        microphone: DictationMicrophone? = nil
    ) {
        self.localeIdentifier = localeIdentifier
        self.microphone = microphone
    }
}

extension AppConfig.Harness {
    public var dictationPreferences: ACPDictationPreferences {
        get { ACPDictationPreferences(localeIdentifier: acpDictationLocale, microphone: acpDictationMicrophone) }
        set {
            acpDictationLocale = newValue.localeIdentifier
            acpDictationMicrophone = newValue.microphone
        }
    }
}
