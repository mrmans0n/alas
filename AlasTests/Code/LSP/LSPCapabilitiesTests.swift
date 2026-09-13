import Foundation
import Testing
@testable import Alas

struct LSPCapabilitiesTests {
    @Test("decodes boolean capability providers")
    func booleanProviders() throws {
        let capabilities = try LSPCapabilities(json: Data("""
        {"hoverProvider":true,"definitionProvider":true,"documentFormattingProvider":false}
        """.utf8))

        #expect(capabilities.supports(.hover))
        #expect(capabilities.supports(.definition))
        #expect(!capabilities.supports(.formatDocument))
    }

    @Test("decodes object capability providers")
    func objectProviders() throws {
        let capabilities = try LSPCapabilities(json: Data("""
        {"definitionProvider":{},"documentFormattingProvider":{},"documentRangeFormattingProvider":{}}
        """.utf8))

        #expect(capabilities.supports(.definition))
        #expect(capabilities.supports(.formatDocument))
        #expect(capabilities.supports(.formatSelection))
    }

    @Test("missing capability providers are unsupported")
    func absentProviders() throws {
        let capabilities = try LSPCapabilities(json: Data("{}".utf8))

        #expect(!capabilities.supports(.hover))
        #expect(!capabilities.supports(.definition))
        #expect(!capabilities.supports(.formatDocument))
    }
}
