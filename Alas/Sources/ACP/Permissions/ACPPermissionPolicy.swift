import Foundation

@MainActor
final class ACPPermissionPolicy {
    let session: ACPSession
    let log: ACPPermissionDecisionLog
    /// Fires as a permission parks for a human decision — the one point where
    /// a permission actually blocks. Auto-run and remembered decisions return
    /// earlier in `evaluate` and deliberately never reach this.
    private let onBlocked: (JSONRPCID, ACPPermissionRequestParams) -> Void

    init(
        session: ACPSession,
        log: ACPPermissionDecisionLog,
        onBlocked: @escaping (JSONRPCID, ACPPermissionRequestParams) -> Void = { _, _ in }
    ) {
        self.session = session
        self.log = log
        self.onBlocked = onBlocked
    }

    /// Decides how to respond to a permission request. If the UI must be
    /// involved, `pendingPermission` is set on the session and the caller's
    /// continuation resumes once the user clicks. Returns the response to send.
    ///
    /// `requestID` is the real JSON-RPC id of this `session/request_permission`
    /// call. It's recorded synchronously (before any `await`) so an inbound
    /// `$/cancel_request` targeting it — via `cancelRequest(id:)` — is never
    /// missed, even if it arrives while this call is still suspended in
    /// `log.lookup` and hasn't parked a UI continuation yet.
    func evaluate(scopeKey: String,
                  options: [ACPPermissionOption],
                  params: ACPPermissionRequestParams,
                  requestID: JSONRPCID) async -> ACPPermissionResponse {
        pendingRequestID = requestID
        cancelledBeforeParked = false
        if session.autoRunEnabled, let allow = options.first(where: { $0.kind.hasPrefix("allow") }) {
            return .init(outcome: .selected(optionId: allow.optionId))
        }
        if let logged = try? await log.lookup(sessionId: session.id, scopeKey: scopeKey) {
            if cancelledBeforeParked { return .init(outcome: .cancelled) }
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
        if cancelledBeforeParked { return .init(outcome: .cancelled) }
        // No auto-decision — bind to UI.
        return await awaitUserDecision(scopeKey: scopeKey, params: params)
    }

    private var pendingContinuation: CheckedContinuation<ACPPermissionResponse, Never>?
    private var pendingRequestID: JSONRPCID?
    private var cancelledBeforeParked = false

    /// The real JSON-RPC id of the permission currently parked for a human,
    /// or nil when nothing is parked. `session.transcript.pendingPermission`
    /// cannot answer this: it is published with a hardcoded `.number(0)`.
    var pendingPermissionRequestID: JSONRPCID? {
        pendingContinuation == nil ? nil : pendingRequestID
    }

    private func awaitUserDecision(scopeKey: String, params: ACPPermissionRequestParams) async -> ACPPermissionResponse {
        session.transcript.streamingState = .awaitingPermission
        session.transcript.pendingPermission = .init(id: .number(0), params: params)
        if let requestID = pendingRequestID {
            onBlocked(requestID, params)
        }
        return await withCheckedContinuation { (c: CheckedContinuation<ACPPermissionResponse, Never>) in
            pendingContinuation = c
        }
    }

    /// Called when an inbound `$/cancel_request` (OpenCode v2) targets
    /// `id`. If a permission is already parked awaiting a user decision,
    /// resolves it immediately as cancelled. If `evaluate` is still
    /// suspended in its auto-decision lookup for this same id, records the
    /// cancellation so `evaluate` returns `.cancelled` itself instead of
    /// parking a prompt nothing will ever dismiss.
    ///
    /// Returns whether `id` matched this policy's in-flight request. A
    /// `$/cancel_request` can arrive before the corresponding
    /// `session/request_permission` has even been dequeued (buffered
    /// broker replay, or a batch delivered ahead of `evaluate` starting);
    /// the caller is responsible for retaining an unmatched id until a
    /// later request with that id actually registers.
    @discardableResult
    func cancelRequest(id: JSONRPCID) -> Bool {
        guard id == pendingRequestID else { return false }
        if pendingContinuation != nil {
            userCancelled()
        } else {
            cancelledBeforeParked = true
        }
        return true
    }

    /// Called by the UI when the user clicks a button. `persistScope` is
    /// .session for Allow/Deny, .project for "Always for this tool", and nil
    /// for Allow-once. Decision recorded if non-nil.
    func userDecided(
        scopeKey: String,
        optionId: String,
        decision: ACPPermissionDecision,
        persistScope: ACPPermissionScopeKind?
    ) async {
        if let scope = persistScope {
            try? await log.record(
                sessionId: session.id,
                scopeKey: scopeKey,
                decision: decision,
                scope: scope
            )
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
