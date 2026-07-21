enum MCPServerRegistration: Equatable {
    case unknown
    case registered
    case notRegistered
}

/// Pure policy for resolving registration from observable signals so the
/// timing wiring in the session manager stays thin and this stays testable.
enum MCPRegistrationDecision {
    static func resolve(helloSeen: Bool, turnStarted: Bool, graceElapsed: Bool) -> MCPServerRegistration {
        if helloSeen { return .registered }
        if turnStarted && graceElapsed { return .notRegistered }
        return .unknown
    }
}
