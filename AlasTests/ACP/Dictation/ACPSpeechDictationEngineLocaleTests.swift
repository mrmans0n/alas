import Foundation
import Testing
@testable import Alas

@Suite("ACP speech dictation locale candidates")
struct ACPSpeechDictationEngineLocaleTests {
    @Test("app locale comes first, then preferred languages, then en_US")
    func orderIsAppLocaleThenPreferredThenFallback() {
        let candidates = ACPSpeechDictationEngine.localeCandidates(
            current: Locale(identifier: "en_ES"),
            preferredLanguages: ["es-ES", "de-DE"]
        )

        #expect(candidates.map(\.identifier) == ["en_ES", "es_ES", "de_DE", "en_US"])
    }

    @Test("duplicates collapse regardless of dash or underscore separators")
    func duplicatesCollapse() {
        let candidates = ACPSpeechDictationEngine.localeCandidates(
            current: Locale(identifier: "en_US"),
            preferredLanguages: ["en-US", "es-ES", "es_ES"]
        )

        #expect(candidates.map(\.identifier) == ["en_US", "es_ES"])
    }

    @Test("an explicit choice leads the chain")
    func explicitChoiceLeadsChain() {
        let candidates = ACPSpeechDictationEngine.localeCandidates(
            explicit: "fr_FR",
            current: Locale(identifier: "en_ES"),
            preferredLanguages: ["es-ES"]
        )

        #expect(candidates.map(\.identifier) == ["fr_FR", "en_ES", "es_ES", "en_US"])
    }

    @Test("the automatic chain is unchanged when no explicit choice is set")
    func noExplicitChoiceKeepsAutomaticChain() {
        for explicit in [nil, ""] as [String?] {
            let candidates = ACPSpeechDictationEngine.localeCandidates(
                explicit: explicit,
                current: Locale(identifier: "en_ES"),
                preferredLanguages: ["es-ES"]
            )

            #expect(candidates.map(\.identifier) == ["en_ES", "es_ES", "en_US"])
        }
    }

    @Test("an explicit choice already in the chain is not duplicated")
    func explicitChoiceIsNotDuplicated() {
        let candidates = ACPSpeechDictationEngine.localeCandidates(
            explicit: "es-ES",
            current: Locale(identifier: "en_ES"),
            preferredLanguages: ["es-ES"]
        )

        #expect(candidates.map(\.identifier) == ["es_ES", "en_ES", "en_US"])
    }
}
