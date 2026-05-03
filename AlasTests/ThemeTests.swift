import Testing
@testable import Alas

struct ThemeTests {
    @Test func decodesBundledCoolSlate() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        #expect(theme.id == "cool-slate")
        #expect(theme.name == "Cool Slate")
        #expect(theme.tokens["accent"] != nil)
    }

    @Test func bundledIdsAreAvailable() {
        let ids = Theme.bundledIds.sorted()
        #expect(ids == ["cool-slate", "light", "neutral", "warm-amber"])
    }
}
