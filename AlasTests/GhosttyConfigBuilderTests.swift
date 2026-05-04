import Testing
@testable import Alas

struct GhosttyConfigBuilderTests {
    @Test func mapsCursorStyle() {
        #expect(GhosttyConfigBuilder.mapCursorStyle("block")     == .block)
        #expect(GhosttyConfigBuilder.mapCursorStyle("beam")      == .beam)
        #expect(GhosttyConfigBuilder.mapCursorStyle("underline") == .underline)
        #expect(GhosttyConfigBuilder.mapCursorStyle("???")       == .beam)
    }

    @Test func mapsToGhosttyCursorStyleString() {
        #expect(GhosttyConfigBuilder.ghosttyCursorStyleString("block")     == "block")
        #expect(GhosttyConfigBuilder.ghosttyCursorStyleString("beam")      == "bar")
        #expect(GhosttyConfigBuilder.ghosttyCursorStyleString("underline") == "underline")
    }
}
