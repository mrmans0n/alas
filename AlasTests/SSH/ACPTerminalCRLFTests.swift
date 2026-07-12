import Testing
@testable import Alas

struct ACPTerminalCRLFTests {
    @Test func collapsesCRLFOnly() {
        #expect(ACPTerminal.normalizeCRLF("a\r\nb\r\n") == "a\nb\n")
        #expect(ACPTerminal.normalizeCRLF("progress\rprogress2\n") == "progress\rprogress2\n")
        #expect(ACPTerminal.normalizeCRLF("") == "")
    }
}
