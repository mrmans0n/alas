import Testing
import Foundation
@testable import Alas

@Suite("MCPHelloEvent")
struct MCPHelloEventTests {
    @Test("decodes a well-formed hello")
    func decodes() throws {
        let data = Data(#"{"v":1,"kind":"mcp_hello","session_id":"S1","transport":"http"}"#.utf8)
        let hello = try MCPHelloEvent.decode(from: data)
        #expect(hello.sessionId == "S1")
        #expect(hello.transport == .http)
    }
    @Test("rejects empty session id")
    func rejectsEmpty() {
        let data = Data(#"{"kind":"mcp_hello","session_id":"","transport":"stdio"}"#.utf8)
        #expect(throws: (any Error).self) { try MCPHelloEvent.decode(from: data) }
    }
    @Test("unknown transport falls back to stdio")
    func unknownTransport() throws {
        let data = Data(#"{"kind":"mcp_hello","session_id":"S1","transport":"weird"}"#.utf8)
        let hello = try MCPHelloEvent.decode(from: data)
        #expect(hello.transport == .stdio)
    }
}
