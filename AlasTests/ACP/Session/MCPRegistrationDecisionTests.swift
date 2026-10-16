import Testing
@testable import Alas

@Suite("MCPRegistrationDecision")
struct MCPRegistrationDecisionTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let evidence: MCPRegistrationEvidence
        let graceElapsed: Bool
        let reattached: Bool
        var requiresFreshHello = false
        let expected: MCPServerRegistration
        var testDescription: String {
            "\(reattached ? "reattach" : "fresh"), \(evidence), grace \(graceElapsed ? "elapsed" : "pending")"
                + (requiresFreshHello ? ", fresh hello required" : "")
        }
    }

    @Test(arguments: [
        // Fresh launch: only the server's own hello proves it started; a
        // request could be the agent's shell running `alas` instead.
        Case(evidence: .hello, graceElapsed: true, reattached: false, expected: .registered),
        Case(evidence: .none, graceElapsed: false, reattached: false, expected: .unknown),
        Case(evidence: .none, graceElapsed: true, reattached: false, expected: .notRegistered),
        Case(evidence: .request, graceElapsed: true, reattached: false, expected: .notRegistered),
        // A request the built-in server tagged as its own proves it at once,
        // unless an adopted agent's fallback `session/new` may have left the
        // previous server running: then only the new server's hello counts.
        Case(evidence: .serverRequest, graceElapsed: false, reattached: false, expected: .registered),
        Case(evidence: .serverRequest, graceElapsed: true, reattached: false, requiresFreshHello: true,
             expected: .notRegistered),
        Case(evidence: .hello, graceElapsed: true, reattached: false, requiresFreshHello: true,
             expected: .registered),
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
            reattachedToRunningServer: c.reattached,
            requiresFreshHello: c.requiresFreshHello
        ) == c.expected)
    }

    struct AdoptionCase: CustomTestStringConvertible, Sendable {
        let label: String
        let servedFromSnapshot: Bool
        var generation: UInt64? = 7
        var fingerprint: String? = "current"
        let record: BuiltInMCPSessionState.AgentRecord?
        let expected: MCPRegistrationDecision.AdoptedAgentServer
        var testDescription: String { label }
    }

    @Test(arguments: [
        AdoptionCase(label: "live startup configures the agent", servedFromSnapshot: false,
                     record: nil, expected: .configuredNow),
        AdoptionCase(label: "adopted agent started with this server", servedFromSnapshot: true,
                     record: .init(brokerGeneration: .init(rawValue: 7), fingerprint: "current"), expected: .kept),
        // An app restart that could not bring the HTTP server back at the
        // agent's address, or a transport switch: the agent calls a dead server.
        AdoptionCase(label: "adopted agent started with another server", servedFromSnapshot: true,
                     record: .init(brokerGeneration: .init(rawValue: 7), fingerprint: "previous"), expected: .outdated),
        AdoptionCase(label: "record from an earlier broker generation", servedFromSnapshot: true,
                     record: .init(brokerGeneration: .init(rawValue: 6), fingerprint: "current"), expected: .outdated),
        AdoptionCase(label: "no record of the adopted agent", servedFromSnapshot: true,
                     record: nil, expected: .outdated),
        AdoptionCase(label: "no built-in server requested", servedFromSnapshot: true, fingerprint: nil,
                     record: nil, expected: .configuredNow),
    ])
    func adoptedAgentServer(_ c: AdoptionCase) {
        #expect(MCPRegistrationDecision.adoptedAgentServer(
            servedFromSnapshot: c.servedFromSnapshot,
            brokerGeneration: c.generation.map(ACPBrokerGeneration.init(rawValue:)),
            fingerprint: c.fingerprint,
            record: c.record
        ) == c.expected)
    }

    @Test(arguments: [
        (MCPRegistrationDecision.AdoptedAgentServer.kept, MCPTransportKind.http, false, true),
        (.kept, .stdio, false, true),
        // A reconnect after this app run already warned: nothing survived.
        (.kept, .stdio, true, false),
        (.outdated, .http, false, false),
        (.configuredNow, .stdio, false, false),
    ])
    func reattachesRunningServer(
        agentServer: MCPRegistrationDecision.AdoptedAgentServer,
        transport: MCPTransportKind,
        previouslyNotRegistered: Bool,
        expected: Bool
    ) {
        #expect(MCPRegistrationDecision.reattachesRunningServer(
            builtInTransport: transport,
            adoptedAgentServer: agentServer,
            previousAttachFoundNoServer: previouslyNotRegistered
        ) == expected)
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

    @Test(arguments: [
        (MCPTransportKind?.none, MCPTransportKind?.some(.stdio), MCPRegistrationEvidence.request),
        (.stdio, .stdio, .serverRequest),
        (.http, .http, .serverRequest),
        // A stdio server left running after switching this attach to HTTP.
        (.stdio, .http, MCPRegistrationEvidence.none),
        (.http, nil, MCPRegistrationEvidence.none),
    ])
    func requestEvidence(
        server: MCPTransportKind?, attached: MCPTransportKind?, expected: MCPRegistrationEvidence
    ) {
        #expect(MCPRegistrationDecision.requestEvidence(
            serverTransport: server, attachedTransport: attached) == expected)
    }

    struct HelloCase: Sendable {
        let sequence: Int?
        let stale: Int?
    }
}
