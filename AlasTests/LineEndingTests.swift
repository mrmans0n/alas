import Testing
import Foundation
@testable import Alas

struct LineEndingTests {
    @Test func detectsLFOnly() {
        #expect(LineEnding.detect(in: "alpha\nbeta\n") == .lf)
    }

    @Test func detectsCRLFOnly() {
        #expect(LineEnding.detect(in: "alpha\r\nbeta\r\n") == .crlf)
    }

    @Test func mixedFavorsCRLF() {
        // Files commonly have a trailing LF but CRLF lines elsewhere; treat
        // the dominant style as CRLF so saves don't silently rewrite the file.
        #expect(LineEnding.detect(in: "alpha\r\nbeta\n") == .crlf)
    }

    @Test func emptyDefaultsToLF() {
        #expect(LineEnding.detect(in: "") == .lf)
    }

    @Test func noLineBreaksDefaultsToLF() {
        #expect(LineEnding.detect(in: "alpha") == .lf)
    }

    @Test func normalizeToLFCollapsesCRLF() {
        #expect(LineEnding.lf.normalize("alpha\r\nbeta") == "alpha\nbeta")
    }

    @Test func normalizeToCRLFExpandsLF() {
        #expect(LineEnding.crlf.normalize("alpha\nbeta") == "alpha\r\nbeta")
    }

    @Test func normalizeToCRLFIsIdempotent() {
        #expect(LineEnding.crlf.normalize("alpha\r\nbeta") == "alpha\r\nbeta")
    }
}
