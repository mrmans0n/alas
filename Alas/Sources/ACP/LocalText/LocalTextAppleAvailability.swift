import Foundation
import FoundationModels

enum LocalTextAppleAvailability: Equatable, Sendable {
    case available, unsupportedOS, deviceNotEligible, disabled
    case modelNotReady, unsupportedLocale, unknown

    var isAvailable: Bool { self == .available }

    static func current(locale: Locale = .current) -> Self {
        guard #available(macOS 26.0, *) else { return .unsupportedOS }
        let model = SystemLanguageModel.default
        return resolve(model.availability, localeSupported: model.supportsLocale(locale))
    }

    @available(macOS 26.0, *)
    static func resolve(
        _ availability: SystemLanguageModel.Availability,
        localeSupported: Bool
    ) -> Self {
        switch availability {
        case .available:
            return localeSupported ? .available : .unsupportedLocale
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .disabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown
            }
        }
    }
}
