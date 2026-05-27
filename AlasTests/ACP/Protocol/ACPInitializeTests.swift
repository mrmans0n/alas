import Foundation
import Testing
@testable import Alas

@Suite("ACP initialize")
struct ACPInitializeTests {
    @Test("decodes an initialize request")
    func decodeRequest() throws {
        let data = try fixture("initialize-request")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPInitializeParams>.self, from: data)
        #expect(env.id == .number(1))
        #expect(env.method == "initialize")
        #expect(env.params?.protocolVersion == 1)
        #expect(env.params?.clientCapabilities.fs.readTextFile == true)
        #expect(env.params?.clientCapabilities.fs.writeTextFile == true)
    }

    @Test("decodes an initialize response")
    func decodeResponse() throws {
        let data = try fixture("initialize-response")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPInitializeResult>.self, from: data)
        #expect(env.result?.protocolVersion == 1)
        #expect(env.result?.authMethods.isEmpty == true)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }
}
