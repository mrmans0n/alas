import Testing
@testable import Alas

struct ChatFontCatalogTests {
    @Test func sortsFamiliesCaseInsensitively() {
        let sorted = ChatFontCatalog.sortedFamilies(["zeta", "Alpha", "beta"])

        #expect(sorted == ["Alpha", "beta", "zeta"])
    }

    @Test func keepsProportionalFamiliesFromAvailableFonts() {
        let families = ChatFontCatalog.sortedFamilies(["Helvetica", "Menlo"])

        #expect(families.contains("Helvetica"))
        #expect(families.contains("Menlo"))
    }
}
