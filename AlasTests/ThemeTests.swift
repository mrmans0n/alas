import Testing
@testable import Alas

struct ThemeTests {
    @Test func decodesBundledCoolSlate() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        #expect(theme.id == "cool-slate")
        #expect(theme.name == "Cool Slate")
        #expect(theme.tokens["accent"] != nil)
    }

    @Test func decodesBundledLight() throws {
        let theme = try Theme.loadBundled(id: "light")
        #expect(theme.id == "light")
        #expect(theme.name == "Light")
        #expect(theme.tokens["accent"] != nil)
    }

    @Test func bundledIdsAreLightAndDark() {
        #expect(Theme.bundledIds.sorted() == ["cool-slate", "light"])
    }

    @Test func darkModeIsFalseForLight() throws {
        let theme = try Theme.loadBundled(id: "light")
        #expect(theme.darkMode == false)
    }

    @Test func darkModeIsTrueForCoolSlate() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        #expect(theme.darkMode == true)
    }
}
