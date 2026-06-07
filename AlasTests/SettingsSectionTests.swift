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
        let labels = SettingsSection.allCases.map(\.label)

        #expect(!labels.contains("Markdown"))
        #expect(labels.contains("General"))
        #expect(labels.contains("Appearance"))
    }

    @Test func sidebarSectionsAreSortedAlphabeticallyExceptDebugLast() {
        let labels = SettingsSection.allCases.map(\.label)
        let mainLabels = labels.filter { $0 != "Debug" }
        #expect(mainLabels == mainLabels.sorted())
        #expect(labels.last == "Debug")
    }
}
