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

    struct ReattachCase: CustomTestStringConvertible, Sendable {
        let builtIn: MCPTransportKind
        let adopted: Bool
        let recordedHello: MCPTransportKind?
        var previouslyNotRegistered = false
        let expected: Bool
        var testDescription: String {
            "\(builtIn), \(adopted ? "adopted" : "spawned"), hello \(recordedHello.map { "\($0)" } ?? "none")"
                + (previouslyNotRegistered ? ", previously not registered" : "")
        }
    }

    @Test(arguments: [
        // A surviving stdio server: no hello yet in this app run, or its own.
        ReattachCase(builtIn: .stdio, adopted: true, recordedHello: nil, expected: true),
        ReattachCase(builtIn: .stdio, adopted: true, recordedHello: .stdio, expected: true),
        // The previous attach used HTTP, so this stdio server is new.
        ReattachCase(builtIn: .stdio, adopted: true, recordedHello: .http, expected: false),
        // A reconnect after this app run already warned: nothing survived.
        ReattachCase(builtIn: .stdio, adopted: true, recordedHello: nil, previouslyNotRegistered: true, expected: false),
        // A freshly spawned agent.
        ReattachCase(builtIn: .stdio, adopted: false, recordedHello: nil, expected: false),
        ReattachCase(builtIn: .http, adopted: false, recordedHello: .http, expected: false),
        // The supervised HTTP server this app run kept: the adapter keeps its
        // connection and sends no new `initialize`, so no new hello.
        ReattachCase(builtIn: .http, adopted: true, recordedHello: .http, expected: true),
        // No HTTP hello in this app run (restarted, or switched from stdio):
        // the server is new and the adapter must connect to it.
        ReattachCase(builtIn: .http, adopted: true, recordedHello: nil, expected: false),
        ReattachCase(builtIn: .http, adopted: true, recordedHello: .stdio, expected: false),
    ])
    func reattachesRunningServer(_ c: ReattachCase) {
        #expect(MCPRegistrationDecision.reattachesRunningServer(
            builtInTransport: c.builtIn,
            adoptedRunningAgent: c.adopted,
            recordedHelloTransport: c.recordedHello,
            previousAttachFoundNoServer: c.previouslyNotRegistered
        ) == c.expected)
    }

    @Test(arguments: [
        (HelloCase(sequence: nil, stale: nil), false),
        (HelloCase(sequence: 3, stale: nil), true),
        // Only the superseded server's hello is on record.
        (HelloCase(sequence: 3, stale: 3), false),
        // The new server said hello after the attach started.
        (HelloCase(sequence: 4, stale: 3), true),
    ])
    func isCurrentHello(_ c: HelloCase, expected: Bool) {
        #expect(MCPRegistrationDecision.isCurrentHello(c.sequence, staleSequence: c.stale) == expected)
    }

    struct HelloCase: Sendable {
        let sequence: Int?
        let stale: Int?
    }
}
