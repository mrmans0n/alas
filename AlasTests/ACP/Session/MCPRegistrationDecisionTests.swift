import Testing
@testable import Alas

@Suite("MCPRegistrationDecision")
struct MCPRegistrationDecisionTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let evidence: MCPRegistrationEvidence
        let graceElapsed: Bool
        let reattached: Bool
        let expected: MCPServerRegistration
        var testDescription: String {
            "\(reattached ? "reattach" : "fresh"), \(evidence), grace \(graceElapsed ? "elapsed" : "pending")"
        }
    }

    @Test(arguments: [
        // Fresh launch: only the server's own hello proves it started; a
        // request could be the agent's shell running `alas` instead.
        Case(evidence: .hello, graceElapsed: true, reattached: false, expected: .registered),
        Case(evidence: .none, graceElapsed: false, reattached: false, expected: .unknown),
        Case(evidence: .none, graceElapsed: true, reattached: false, expected: .notRegistered),
        Case(evidence: .request, graceElapsed: true, reattached: false, expected: .notRegistered),
        // Re-attached to a running server that already said its one hello:
        // never warn without evidence, and its first request proves it.
        Case(evidence: .none, graceElapsed: true, reattached: true, expected: .unknown),
        Case(evidence: .request, graceElapsed: false, reattached: true, expected: .registered),
        Case(evidence: .hello, graceElapsed: true, reattached: true, expected: .registered),
    ])
    func resolve(_ c: Case) {
        #expect(MCPRegistrationDecision.resolve(
            evidence: c.evidence,
            graceElapsed: c.graceElapsed,
            reattachedToRunningServer: c.reattached
        ) == c.expected)
    }
}
