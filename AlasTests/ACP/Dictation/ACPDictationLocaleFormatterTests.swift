import Foundation
import Testing
@testable import Alas

@Suite("ACP dictation locale names and menu")
struct ACPDictationLocaleFormatterTests {
    @Test("locale identifiers render as English display names")
    func identifiersRenderAsEnglishNames() {
        #expect(ACPDictationLocaleFormatter.displayName(for: "en_US") == "English (United States)")
        #expect(ACPDictationLocaleFormatter.displayName(for: "es_ES") == "Spanish (Spain)")
        #expect(ACPDictationLocaleFormatter.displayName(for: "pt_BR") == "Portuguese (Brazil)")
    }

    @Test("an empty identifier is the automatic choice")
    func emptyIdentifierIsAutomatic() {
        #expect(ACPDictationLocaleFormatter.displayName(for: "") == "Automatic")
    }

    @Test("identifiers sort by display name, not raw code")
    func sortsByDisplayName() {
        // A discriminating case: sorting the raw identifiers would give
        // de_DE, en_US, es_ES, but the names are German, English, Spanish,
        // so English must come first.
        let sorted = ACPDictationLocaleFormatter.sortedByDisplayName(["es_ES", "en_US", "de_DE"])
        #expect(sorted == ["en_US", "de_DE", "es_ES"])
    }

    @Test("menu lists automatic first, then installed languages by name")
    func menuListsAutomaticFirst() {
        let items = ACPComposerControlPresentation.dictationMenuItems(
            installed: ["es_ES", "en_US"],
            selected: ""
        )

        #expect(items.map(\.localeIdentifier) == ["", "en_US", "es_ES"])
        #expect(items.map(\.title) == ["Automatic", "English (United States)", "Spanish (Spain)"])
        #expect(items.map(\.isSelected) == [true, false, false])
    }

    @Test("the chosen language is the one marked selected")
    func chosenLanguageIsMarked() {
        let items = ACPComposerControlPresentation.dictationMenuItems(
            installed: ["es_ES", "en_US"],
            selected: "es_ES"
        )

        #expect(items.map(\.isSelected) == [false, false, true])
    }

    @Test("a chosen language that is not installed still appears, so the menu shows the truth")
    func chosenLanguageAppearsEvenWhenNotInstalled() {
        let items = ACPComposerControlPresentation.dictationMenuItems(
            installed: ["en_US"],
            selected: "fr_FR"
        )

        #expect(items.map(\.localeIdentifier) == ["", "en_US", "fr_FR"])
        #expect(items.first(where: { $0.localeIdentifier == "fr_FR" })?.isSelected == true)
    }
}
