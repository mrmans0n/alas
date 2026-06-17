import Testing
@testable import Alas

struct IconSymbolTests {
    @Test func homeMapsToHouse() {
        #expect(Icon.symbol(for: "home") == "house")
    }

    @Test func branchMappingUnchanged() {
        #expect(Icon.symbol(for: "branch") == "arrow.triangle.branch")
    }

    @Test func codeHostIconsUseCustomGlyphs() {
        #expect(Icon.symbol(for: "github") == "github")
        #expect(Icon.symbol(for: "gitlab") == "gitlab")
        #expect(Icon.rendersCustomGlyph(for: "github"))
        #expect(Icon.rendersCustomGlyph(for: "gitlab"))
    }
}
