import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Lifecycle of the composer's push-to-talk dictation control.
///
/// `.unavailable` means no speech-to-text engine exists for this OS/locale —
/// the mic button isn't shown at all in that case. Every other case assumes
/// the button is visible.
public enum ACPDictationState: Equatable, Sendable {
    case unavailable
    case idle
    case preparing
    case listening
    case failed(String)
}
