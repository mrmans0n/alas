import Testing
@testable import Alas

struct SettingsSectionTests {
    @Test func sidebarSectionsDoNotIncludeStandaloneMarkdown() {
        let labels = SettingsSection.allCases.map(\.label)

        #expect(!labels.contains("Markdown"))
        #expect(!labels.contains("General"))
        #expect(labels.contains("Appearance"))
    }

    @Test func sidebarSectionsAreSortedAlphabetically() {
        let labels = SettingsSection.allCases.map(\.label)
        #expect(labels == labels.sorted())
    }
}
