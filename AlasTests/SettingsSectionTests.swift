import Testing
@testable import Alas

struct SettingsSectionTests {
    @Test func settingsRowColumnsSplitAvailableWidthEvenly() {
        #expect(SettingsRowLayout.columnWidth(for: 616) == 300)
        #expect(SettingsRowLayout.columnWidth(for: 680) == 332)
    }

    @Test func settingsRowColumnWidthDoesNotGoNegative() {
        #expect(SettingsRowLayout.columnWidth(for: 0) == 0)
        #expect(SettingsRowLayout.columnWidth(for: 8) == 0)
    }

    @Test func settingsDropdownControlsUseStandardWidth() {
        #expect(SettingsRowLayout.dropdownControlWidth == 240)
    }

    @Test func sidebarSectionsDoNotIncludeStandaloneMarkdown() {
        let labels = SettingsSection.visibleSections(showsDebug: true).map(\.label)

        #expect(!labels.contains("Markdown"))
    }

    @Test func sidebarSectionsIncludeChat() {
        let labels = SettingsSection.visibleSections(showsDebug: false).map(\.label)

        #expect(labels.contains("General"))
        #expect(labels.contains("Appearance"))
        #expect(labels.contains("Chat"))
    }

    @Test func sidebarSectionsAreSortedAlphabeticallyExceptDebugLast() {
        let sections = SettingsSection.visibleSections(showsDebug: true)
        let labels = sections.map(\.label)
        let mainLabels = Array(labels.dropFirst().dropLast())
        #expect(labels.first == "General")
        #expect(mainLabels == mainLabels.sorted())
        #expect(labels.last == "Debug")
    }

    @Test func sidebarSectionsHideDebugWhenDisabled() {
        let labels = SettingsSection.visibleSections(showsDebug: false).map(\.label)

        #expect(!labels.contains("Debug"))
    }
}
