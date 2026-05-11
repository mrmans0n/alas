import Testing
@testable import Alas

struct SettingsSectionTests {
    @Test func sidebarSectionsDoNotIncludeStandaloneMarkdown() {
        let labels = SettingsSection.allCases.map(\.label)

        #expect(!labels.contains("Markdown"))
        #expect(labels.contains("Appearance"))
    }
}
