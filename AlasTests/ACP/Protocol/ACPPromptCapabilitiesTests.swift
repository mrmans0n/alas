import Foundation
import Testing
@testable import Alas

@Suite("ACP prompt capabilities decoding")
struct ACPPromptCapabilitiesTests {
    @Test("image-only capabilities decode with audio defaulting to false")
    func imageOnlyDecodes() throws {
        // ACP defines each prompt capability as defaulting to false, so an
        // agent advertising only `image` must still decode and report image
        // support (rather than failing the whole initialize result).
        let json = #"""
        {"protocolVersion":1,"agentCapabilities":{"promptCapabilities":{"image":true}},"authMethods":[]}
        """#.data(using: .utf8)!
        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: json)
        #expect(result.agentCapabilities?.promptCapabilities?.image == true)
        #expect(result.agentCapabilities?.promptCapabilities?.audio == false)
    }
}
