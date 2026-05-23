import Testing
@testable import Alas

struct SettingsSectionTests {
    @Test func sidebarSectionsDoNotIncludeStandaloneMarkdown() {
        let labels = SettingsSection.allCases.map(\.label)

        #expect(!labels.contains("Markdown"))
        #expect(!labels.contains("General"))
        #expect(labels.contains("Appearance"))
    }

    @Test func sidebarSectionsAreSortedAlphabeticallyExceptDebugLast() {
        let labels = SettingsSection.allCases.map(\.label)
        let mainLabels = labels.filter { $0 != "Debug" }
        #expect(mainLabels == mainLabels.sorted())
        #expect(labels.last == "Debug")
    }
}
