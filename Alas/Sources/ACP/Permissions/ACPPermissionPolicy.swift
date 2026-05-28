import Foundation

@MainActor
final class ACPPermissionPolicy {
    let session: ACPSession
    let log: ACPPermissionDecisionLog

    init(session: ACPSession, log: ACPPermissionDecisionLog) {
        self.session = session
        self.log = log
    }

    /// Decides how to respond to a permission request. If the UI must be
    /// involved, `pendingPermission` is set on the session and the caller's
    /// continuation resumes once the user clicks. Returns the response to send.
    func evaluate(scopeKey: String,
                  options: [ACPPermissionOption],
                  params: ACPPermissionRequestParams) async -> ACPPermissionResponse {
        if session.autoRunEnabled, let allow = options.first(where: { $0.kind.hasPrefix("allow") }) {
            return .init(outcome: .selected(optionId: allow.optionId))
        }
        if let logged = try? log.lookup(sessionId: session.id, scopeKey: scopeKey) {
            switch logged {
            case .allow:
                if let allow = options.first(where: { $0.kind.hasPrefix("allow") }) {
                    return .init(outcome: .selected(optionId: allow.optionId))
                }
            case .deny:
                if let deny = options.first(where: { $0.kind.hasPrefix("reject") }) {
                    return .init(outcome: .selected(optionId: deny.optionId))
                }
            }
        }
        // No auto-decision — bind to UI.
        return await awaitUserDecision(scopeKey: scopeKey, params: params)
    }

    private var pendingContinuation: CheckedContinuation<ACPPermissionResponse, Never>?

    private func awaitUserDecision(scopeKey: String, params: ACPPermissionRequestParams) async -> ACPPermissionResponse {
        session.transcript.streamingState = .awaitingPermission
        session.transcript.pendingPermission = .init(id: .number(0), params: params)
        return await withCheckedContinuation { (c: CheckedContinuation<ACPPermissionResponse, Never>) in
            pendingContinuation = c
        }
    }

    /// Called by the UI when the user clicks a button. `persistScope` is
    /// .session for Allow/Deny, .project for "Always for this tool", and nil
    /// for Allow-once. Decision recorded if non-nil.
    func userDecided(scopeKey: String, optionId: String, decision: ACPPermissionDecision, persistScope: ACPPermissionScopeKind?) {
        if let scope = persistScope {
            try? log.record(sessionId: session.id, scopeKey: scopeKey, decision: decision, scope: scope)
        }
        session.transcript.pendingPermission = nil
        session.transcript.streamingState = .streaming
        let cont = pendingContinuation
        pendingContinuation = nil
        cont?.resume(returning: .init(outcome: .selected(optionId: optionId)))
    }

    func userCancelled() {
        session.transcript.pendingPermission = nil
        session.transcript.streamingState = .idle
        let cont = pendingContinuation
        pendingContinuation = nil
        cont?.resume(returning: .init(outcome: .cancelled))
    }
}
