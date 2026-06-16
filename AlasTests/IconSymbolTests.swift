import Testing
@testable import Alas

struct IconSymbolTests {
    @Test func homeMapsToHouse() {
        #expect(Icon.symbol(for: "home") == "house")
    }

    @Test func branchMappingUnchanged() {
        #expect(Icon.symbol(for: "branch") == "arrow.triangle.branch")
    }
}
