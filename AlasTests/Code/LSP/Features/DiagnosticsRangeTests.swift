import Foundation
import Testing
@testable import Alas

@Suite("DiagnosticsRange")
struct DiagnosticsRangeTests {
    @Test("LSP range translates to NSRange across newlines")
    func translate() {
        let src = "abc\ndef\nghi"
        let r = LSPRange(
            start: LSPPosition(line: 1, character: 1),
            end: LSPPosition(line: 1, character: 3)
        )
        let nsr = DiagnosticsFeature.nsRange(for: r, in: src)
        #expect(nsr == NSRange(location: 5, length: 2))
    }

    @Test("UTF-16 character offsets account for multi-byte chars")
    func utf16() {
        // "é" is one UTF-16 code unit but 2 UTF-8 bytes.
        let src = "é\nbar"
        let r = LSPRange(
            start: LSPPosition(line: 1, character: 0),
            end: LSPPosition(line: 1, character: 3)
        )
        let nsr = DiagnosticsFeature.nsRange(for: r, in: src)
        #expect(nsr == NSRange(location: 2, length: 3))
    }
}
