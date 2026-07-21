import Testing
@testable import Alas

@Suite("MCPRegistrationDecision")
struct MCPRegistrationDecisionTests {
    @Test("registered when hello seen")
    func registered() {
        #expect(MCPRegistrationDecision.resolve(helloSeen: true, graceElapsed: true) == .registered)
    }
    @Test("unknown before grace elapses")
    func unknownEarly() {
        #expect(MCPRegistrationDecision.resolve(helloSeen: false, graceElapsed: false) == .unknown)
    }
    @Test("notRegistered only after grace with no hello")
    func notRegistered() {
        #expect(MCPRegistrationDecision.resolve(helloSeen: false, graceElapsed: true) == .notRegistered)
        #expect(MCPRegistrationDecision.resolve(helloSeen: false, graceElapsed: false) == .unknown)
    }
}
