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

    @Test func posixQuoteLeavesSafeStringsBare() {
        #expect(GhosttyConfigBuilder.posixQuote("/bin/zsh") == "/bin/zsh")
        #expect(GhosttyConfigBuilder.posixQuote("--rcfile") == "--rcfile")
        #expect(GhosttyConfigBuilder.posixQuote("-i") == "-i")
        #expect(GhosttyConfigBuilder.posixQuote("UTF-8") == "UTF-8")
    }

    @Test func posixQuoteWrapsPathsWithSpaces() {
        // The common offender: ~/Library/Application Support/...
        let path = "/Users/me/Library/Application Support/Alas/rcfiles/abc.bashrc"
        #expect(
            GhosttyConfigBuilder.posixQuote(path)
                == "'/Users/me/Library/Application Support/Alas/rcfiles/abc.bashrc'"
        )
    }

    @Test func posixQuoteEscapesEmbeddedSingleQuotes() {
        // Standard shell trick: '...'\''...'
        #expect(GhosttyConfigBuilder.posixQuote("it's a path") == "'it'\\''s a path'")
    }

    @Test func posixQuoteEmptyStringIsEmptyQuotes() {
        #expect(GhosttyConfigBuilder.posixQuote("") == "''")
    }
}
