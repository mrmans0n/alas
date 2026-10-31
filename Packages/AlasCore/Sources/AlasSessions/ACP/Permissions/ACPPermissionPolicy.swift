import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

@MainActor
public final class ACPPermissionPolicy {
    nonisolated public let session: ACPSession
    nonisolated public let log: ACPPermissionDecisionLog
    /// Fires as a permission parks for a human decision — the one point where
    /// a permission actually blocks. Auto-run and remembered decisions return
    /// earlier in `evaluate` and deliberately never reach this.
    private let onBlocked: (JSONRPCID, ACPPermissionRequestParams) -> Void

    public init(
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
    public func evaluate(scopeKey: String,
                  options: [ACPPermissionOption],
                  params: ACPPermissionRequestParams,
                  requestID: JSONRPCID) async -> ACPPermissionResponse {
        pendingRequestID = requestID
        cancelledBeforeParked = false
        // Ahead of auto-run and remembered decisions: a project-wide "always
        // allow" must not let a read-only side session write.
        if session.readOnlyRestricted {
            switch ACPSideQuestionPermissionRule.decide(kind: params.toolCall.kind) {
            case .allow:
                // Never a persistent allow: the adapter could stop asking for
                // that scope, and later calls would skip this gate.
                if let allow = options.first(where: { $0.kind == "allow_once" }) {
                    return .init(outcome: .selected(optionId: allow.optionId))
                }
            case .reject:
                session.recordReadOnlyBlock(params.toolCall.title ?? params.toolCall.kind ?? "tool")
                // Never a persistent rejection either: a kept session must be
                // able to use the tool.
                if let reject = options.first(where: { $0.kind == "reject_once" }) {
                    return .init(outcome: .selected(optionId: reject.optionId))
                }
                return .init(outcome: .cancelled)
            case .ask:
                break
            }
            // The prompt offers one-shot choices only, for the same reason.
            let oneShot = params.options.filter { $0.kind == "allow_once" || $0.kind == "reject_once" }
            guard !oneShot.isEmpty else { return .init(outcome: .cancelled) }
            return await awaitUserDecision(
                scopeKey: scopeKey,
                params: ACPPermissionRequestParams(
                    sessionId: params.sessionId,
                    toolCall: params.toolCall,
                    options: oneShot,
                    metadata: params.metadata
                )
            )
        }
        if session.autoRunEnabled, let allow = options.first(where: { $0.kind.hasPrefix("allow") }) {
            return .init(outcome: .selected(optionId: allow.optionId))
        }
        var logged = deliveredDecisions[scopeKey]
        if logged == nil {
            logged = try? await log.lookup(sessionId: session.id, scopeKey: scopeKey)
        }
        if let logged {
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
    /// Remembered answers this policy delivered, so the agent's next request
    /// gets them at once rather than only after their record lands.
    private var deliveredDecisions: [String: ACPPermissionDecision] = [:]
    /// The streaming state the session was in when a permission parked. A
    /// background child can ask after its parent's turn settled, so the
    /// answer must not claim a turn that is no longer running.
    private var stateBeforePark: ACPSession.StreamingState?

    /// The real JSON-RPC id of the permission currently parked for a human,
    /// or nil when nothing is parked. `session.transcript.pendingPermission`
    /// cannot answer this: it is published with a hardcoded `.number(0)`.
    ///
    /// Not yet set during the synchronous extent of the `onBlocked` callback
    /// in `awaitUserDecision` below — the continuation that gates this
    /// accessor is only recorded immediately afterward. A synchronous
    /// observer of `onBlocked` must use that callback's own `requestID`
    /// argument, not this accessor.
    public var pendingPermissionRequestID: JSONRPCID? {
        pendingContinuation == nil ? nil : pendingRequestID
    }

    private func awaitUserDecision(scopeKey: String, params: ACPPermissionRequestParams) async -> ACPPermissionResponse {
        if stateBeforePark == nil {
            stateBeforePark = session.transcript.streamingState
        }
        session.transcript.streamingState = .awaitingPermission
        session.transcript.pendingPermission = .init(id: .number(0), params: params)
        if let requestID = pendingRequestID {
            // `pendingPermissionRequestID` still reads nil here: `pendingContinuation`
            // is only assigned after this callback returns.
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
    public func cancelRequest(id: JSONRPCID) -> Bool {
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
    /// Records the decision and answers the pending request with it. The
    /// request is taken before anything is awaited, so a caller that checks
    /// for it first never races another for the same one. `stillAuthorized`,
    /// asked right before the agent resumes, can withhold the answer: the
    /// request is then cancelled. Returns whether a request was pending and
    /// the answer reached it.
    @discardableResult
    public func userDecided(
        scopeKey: String,
        optionId: String,
        decision: ACPPermissionDecision,
        persistScope: ACPPermissionScopeKind?,
        stillAuthorized: (@MainActor () async -> Bool)? = nil
    ) async -> Bool {
        let wasPending = pendingContinuation != nil || session.transcript.pendingPermission != nil
        let cont = pendingContinuation
        pendingContinuation = nil
        session.transcript.pendingPermission = nil
        if session.transcript.streamingState == .awaitingPermission {
            session.transcript.streamingState = stateBeforePark == .idle ? .idle : .streaming
        }
        stateBeforePark = nil
        if let stillAuthorized, await !stillAuthorized() {
            cont?.resume(returning: .init(outcome: .cancelled))
            return false
        }
        // The agent may have withdrawn the request while this awaited: with
        // the continuation taken, `cancelRequest` only records that.
        if cont != nil, cancelledBeforeParked {
            cont?.resume(returning: .init(outcome: .cancelled))
            return false
        }
        if persistScope != nil {
            deliveredDecisions[scopeKey] = decision
        }
        cont?.resume(returning: .init(outcome: .selected(optionId: optionId)))
        // Recorded once delivered, so an answer that never reached the agent
        // is never remembered for the next request; still before returning.
        if let scope = persistScope {
            try? await log.record(
                sessionId: session.id,
                scopeKey: scopeKey,
                decision: decision,
                scope: scope
            )
        }
        return wasPending
    }

    public func userCancelled() {
        session.transcript.pendingPermission = nil
        session.transcript.streamingState = .idle
        stateBeforePark = nil
        let cont = pendingContinuation
        pendingContinuation = nil
        cont?.resume(returning: .init(outcome: .cancelled))
    }
}
