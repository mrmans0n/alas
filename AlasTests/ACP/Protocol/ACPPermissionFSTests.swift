import Foundation
import Testing
@testable import Alas

@Suite("ACP permission + filesystem")
struct ACPPermissionFSTests {
    @Test("decodes a permission request")
    func permission() throws {
        let data = try fixture("permission-request")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPPermissionRequestParams>.self, from: data)
        let p = try #require(env.params)
        #expect(p.sessionId == "sess-abc")
        #expect(p.toolCall.toolCallId == "tc-9")
        #expect(p.options.count == 3)
        #expect(p.options[0].kind == "allow_once")
    }

    @Test("decodes fs/write_text_file")
    func fsWrite() throws {
        let data = try fixture("fs-write")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPFsWriteParams>.self, from: data)
        #expect(env.params?.path == "/Users/me/proj/foo.txt")
        #expect(env.params?.content == "hi")
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }
}
