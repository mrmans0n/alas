import FoundationModels
import Testing
@testable import Alas

struct LocalTextAppleAvailabilityTests {
    @available(macOS 26.0, *)
    @Test(arguments: [
        (SystemLanguageModel.Availability.available, true, LocalTextAppleAvailability.available),
        (.available, false, .unsupportedLocale),
        (.unavailable(.deviceNotEligible), false, .deviceNotEligible),
        (.unavailable(.appleIntelligenceNotEnabled), false, .disabled),
        (.unavailable(.modelNotReady), false, .modelNotReady)
    ])
    func systemRestrictionTakesPrecedenceOverLocale(
        system: SystemLanguageModel.Availability,
        localeSupported: Bool,
        expected: LocalTextAppleAvailability
    ) {
        #expect(LocalTextAppleAvailability.resolve(system, localeSupported: localeSupported) == expected)
    }
}
