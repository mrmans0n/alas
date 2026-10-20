import Foundation
import Testing
@testable import Alas

@Suite("ACP dictation locale names and mic menus")
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
        let items = ACPComposerControlPresentation.languageMenuItems(
            installed: ["es_ES", "en_US"],
            selected: ""
        )

        #expect(items.map(\.identifier) == ["", "en_US", "es_ES"])
        #expect(items.map(\.title) == ["Automatic", "English (United States)", "Spanish (Spain)"])
        #expect(items.map(\.isSelected) == [true, false, false])
    }

    @Test("the chosen language is the one marked selected")
    func chosenLanguageIsMarked() {
        let items = ACPComposerControlPresentation.languageMenuItems(
            installed: ["es_ES", "en_US"],
            selected: "es_ES"
        )

        #expect(items.map(\.isSelected) == [false, false, true])
    }

    @Test("a chosen language that is not installed still appears, so the menu shows the truth")
    func chosenLanguageAppearsEvenWhenNotInstalled() {
        let items = ACPComposerControlPresentation.languageMenuItems(
            installed: ["en_US"],
            selected: "fr_FR"
        )

        #expect(items.map(\.identifier) == ["", "en_US", "fr_FR"])
        #expect(items.first(where: { $0.identifier == "fr_FR" })?.isSelected == true)
    }

    private static let builtIn = ACPAudioInputDevice(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private static let usb = ACPAudioInputDevice(id: 2, uid: "usb-podcaster", name: "Podcaster")
    private static let away = DictationMicrophone(uid: "bt-headset", name: "Headset")

    @Test("microphone menu lists the system default first, then connected inputs by name")
    func microphoneMenuListsSystemDefaultFirst() {
        let items = ACPComposerControlPresentation.microphoneMenuItems(available: [Self.usb, Self.builtIn], selected: nil)

        #expect(items.map(\.identifier) == ["", "BuiltInMicrophoneDevice", "usb-podcaster"])
        #expect(items.map(\.isSelected) == [true, false, false])
    }

    @Test("a chosen microphone that is not connected still appears, selected")
    func disconnectedMicrophoneStaysSelected() {
        let items = ACPComposerControlPresentation.microphoneMenuItems(available: [Self.builtIn], selected: Self.away)

        #expect(items.map(\.identifier) == ["", "BuiltInMicrophoneDevice", "bt-headset"])
        #expect(items.last?.title == "Headset (not connected)")
        #expect(items.map(\.isSelected) == [false, false, true])
    }

    @Test(
        "a microphone menu entry maps back to the microphone it stands for",
        arguments: [
            ("BuiltInMicrophoneDevice", DictationMicrophone(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")),
            // The saved name, not the "(not connected)" menu title.
            ("bt-headset", DictationMicrophone(uid: "bt-headset", name: "Headset")),
            ("", nil),
        ] as [(String, DictationMicrophone?)]
    )
    func menuIdentifierMapsToMicrophone(identifier: String, expected: DictationMicrophone?) {
        let microphone = ACPComposerControlPresentation.microphone(
            forMenuIdentifier: identifier,
            available: [Self.builtIn],
            selected: Self.away
        )

        #expect(microphone == expected)
    }
}
