import Foundation
import Testing
@testable import Alas

@Suite("ACPStdioClient terminal dispatch")
struct ACPStdioTerminalDispatchTests {
    @Test("terminal/create incoming frame yields ACPTerminalRequest.create")
    func dispatchesCreate() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()
        let json = #"""
        {"jsonrpc":"2.0","id":42,"method":"terminal/create","params":{
          "sessionId":"s","command":"echo","args":["hi"]
        }}
        """#
        transport.send(frame: Data(json.utf8))
        var it = client.terminalRequests.makeAsyncIterator()
        let req = await it.next()
        guard case .create(let id, let p) = req else {
            Issue.record("expected .create, got \(String(describing: req))")
            return
        }
        #expect(id == .number(42))
        #expect(p.command == "echo")
        #expect(p.args == ["hi"])
    }
}
