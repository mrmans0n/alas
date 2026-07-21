import Testing
@testable import Alas

@MainActor
@Suite("MCPRegistrationRegistry")
struct MCPRegistrationRegistryTests {
    @Test("records and reports a hello")
    func records() {
        let r = MCPRegistrationRegistry()
        #expect(r.isRegistered(sessionId: "S1") == false)
        r.recordHello(sessionId: "S1", transport: .stdio)
        #expect(r.isRegistered(sessionId: "S1") == true)
    }
    @Test("clear on new attach epoch drops the record")
    func clear() {
        let r = MCPRegistrationRegistry()
        r.recordHello(sessionId: "S1", transport: .http)
        r.clear(sessionId: "S1")
        #expect(r.isRegistered(sessionId: "S1") == false)
    }
}
