import Testing
@testable import Alas

@Suite("MCPRegistrationDecision")
struct MCPRegistrationDecisionTests {
    @Test("registered when hello seen")
    func registered() {
        #expect(MCPRegistrationDecision.resolve(helloSeen: true, turnStarted: true, graceElapsed: true) == .registered)
    }
    @Test("unknown before first turn completes")
    func unknownEarly() {
        #expect(MCPRegistrationDecision.resolve(helloSeen: false, turnStarted: false, graceElapsed: false) == .unknown)
    }
    @Test("notRegistered only after turn + grace with no hello")
    func notRegistered() {
        #expect(MCPRegistrationDecision.resolve(helloSeen: false, turnStarted: true, graceElapsed: true) == .notRegistered)
        #expect(MCPRegistrationDecision.resolve(helloSeen: false, turnStarted: true, graceElapsed: false) == .unknown)
    }
}
