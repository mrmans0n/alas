import Foundation
import Combine

/// Bridges one remote WebSocket connection to the in-process ACP world.
///
/// Transport-agnostic: it consumes decoded `RemoteClientMessage`s and emits
/// `RemoteServerMessage`s via the `send` closure, so it is fully testable
/// without sockets. Observes the live `ACPTranscript` (Combine) and
/// re-snapshots on change (coalesced) as a "delta". Inbound permission
/// decisions route to the existing `ACPPermissionPolicy.userDecided(...)`
/// after a first-wins staleness guard.
@MainActor
final class RemoteSessionGateway {
    private let provider: RemoteSessionsProvider
    private let send: (RemoteServerMessage) -> Void
    private var subscriptions: [String: AnyCancellable] = [:]
    private var coalesce: [String: Task<Void, Never>] = [:]
    // Per-session request id of the permission/question prompt we last surfaced,
    // so we can tell the client to dismiss it if it gets resolved elsewhere.
    private var lastPermissionReq: [String: Int] = [:]
    private var lastQuestionReq: [String: Int] = [:]
    private static let coalesceNanos: UInt64 = 80_000_000  // ~80ms

    init(provider: RemoteSessionsProvider, send: @escaping (RemoteServerMessage) -> Void) {
        self.provider = provider
        self.send = send
    }

    func handle(_ message: RemoteClientMessage) async {
        switch message {
        case .listSessions:
            send(.sessionList(sessions: provider.sessionSummaries()))
        case .subscribe(let id):
            await provider.hydrateIfNeeded(id: id)
            guard let session = provider.session(for: id) else {
                send(.sessionClosed(sessionId: id))
                return
            }
            sendSnapshot(id: id, session: session)
            observe(id: id, session: session)
        case .unsubscribe(let id):
            subscriptions[id] = nil
            coalesce[id]?.cancel()
            coalesce[id] = nil
            lastPermissionReq[id] = nil
            lastQuestionReq[id] = nil
        case .permissionDecision(let id, let requestId, let optionId, let persistScope):
            applyDecision(sessionId: id, requestId: requestId, optionId: optionId, persistScope: persistScope)
        case .questionAnswer(let id, let requestId, let answers):
            applyQuestionAnswer(sessionId: id, requestId: requestId, answers: answers)
        case .takeOver(let id):
            provider.takeOver(for: id)
            // Takeover seizes the writer lease synchronously but mostly mutates
            // lease/agent state, not the transcript — so the objectWillChange
            // delta that normally carries `canDrive` may never fire on an idle
            // session. Push a snapshot now so the client learns canDrive=true
            // immediately and the composer unlocks (otherwise the take-over
            // button stays up and sendPrompt stays blocked until some unrelated
            // transcript mutation happens to occur).
            if let session = provider.session(for: id) {
                sendSnapshot(id: id, session: session)
            }
        case .sendPrompt(let id, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard provider.isWriter(for: id), !trimmed.isEmpty else { return }
            provider.sendPrompt(for: id, text: trimmed)
        case .stop(let id):
            guard provider.isWriter(for: id) else { return }
            provider.stop(for: id)
        }
    }

    /// Tear down all observation (called when the connection closes).
    func close() {
        subscriptions.removeAll()
        coalesce.values.forEach { $0.cancel() }
        coalesce.removeAll()
        lastPermissionReq.removeAll()
        lastQuestionReq.removeAll()
    }

    // MARK: snapshot / delta

    private func sendSnapshot(id: String, session: ACPSession) {
        let wire = session.transcript.messages.enumerated().map { Self.toWire($0.element, index: $0.offset) }
        send(.transcriptSnapshot(sessionId: id,
                                 streamingState: Self.stateString(session.transcript.streamingState),
                                 canDrive: provider.isWriter(for: id),
                                 messages: wire))
        emitPendingPermissionIfAny(id: id, session: session)
        emitPendingQuestionIfAny(id: id, session: session)
    }

    private func observe(id: String, session: ACPSession) {
        // Replace any existing subscription / pending coalesce for this id so a
        // re-subscribe can't leave an orphaned timer firing one stray delta.
        subscriptions[id]?.cancel()
        coalesce[id]?.cancel()
        // ACPTranscript is an ObservableObject; objectWillChange fires on any
        // @Published mutation (new message, streaming chunk, pending permission).
        subscriptions[id] = session.transcript.objectWillChange.sink { [weak self, weak session] _ in
            guard let self, let session else { return }
            // Coalesce bursts of streaming chunks into one delta.
            self.coalesce[id]?.cancel()
            self.coalesce[id] = Task { @MainActor [weak self, weak session] in
                try? await Task.sleep(nanoseconds: Self.coalesceNanos)
                guard !Task.isCancelled, let self, let session else { return }
                self.sendDelta(id: id, session: session)
            }
        }
    }

    private func sendDelta(id: String, session: ACPSession) {
        // v1: send a full re-snapshot as the "delta" (simple + always correct).
        // A true per-message diff optimization is intentionally deferred (YAGNI).
        let wire = session.transcript.messages.enumerated().map { Self.toWire($0.element, index: $0.offset) }
        send(.transcriptDelta(sessionId: id,
                              streamingState: Self.stateString(session.transcript.streamingState),
                              canDrive: provider.isWriter(for: id),
                              upserts: wire))
        emitPendingPermissionIfAny(id: id, session: session)
        emitPendingQuestionIfAny(id: id, session: session)
    }

    private func emitPendingPermissionIfAny(id: String, session: ACPSession) {
        // Only surface a prompt when the session is genuinely awaiting it. A
        // read-only mirror (no runner) can carry a stale pending* while idle —
        // surfacing that would show a prompt the remote can't actually answer.
        if session.transcript.streamingState == .awaitingPermission,
           let pending = session.transcript.pendingPermission {
            let rid = Self.requestIdInt(pending.id)
            lastPermissionReq[id] = rid
            let tc = pending.params.toolCall
            let payload = RemotePermissionPayload(
                requestId: rid,
                toolName: tc.title ?? tc.kind ?? "tool",
                options: pending.params.options.map {
                    RemotePermissionOption(optionId: $0.optionId, name: $0.name, kind: $0.kind)
                })
            send(.permissionRequest(sessionId: id, payload: payload))
        } else if let rid = lastPermissionReq.removeValue(forKey: id) {
            // A prompt we surfaced was resolved elsewhere (the Mac or another
            // client) — tell the client to dismiss it so it doesn't hang.
            send(.permissionResolved(sessionId: id, requestId: rid))
        }
    }

    private func emitPendingQuestionIfAny(id: String, session: ACPSession) {
        // Only when the session is actually awaiting input (see the permission
        // note above) and there's something answerable.
        if session.transcript.streamingState == .awaitingInput,
           let pending = session.transcript.pendingQuestion,
           !pending.params.questions.isEmpty {
            let rid = Self.requestIdInt(pending.id)
            lastQuestionReq[id] = rid
            let payload = RemoteQuestionPayload(
                requestId: rid,
                title: pending.params.title,
                questions: pending.params.questions.map { q in
                    RemoteQuestion(
                        id: q.id,
                        prompt: q.prompt,
                        options: q.options.map { RemoteQuestionOption(id: $0.id, label: $0.label) },
                        allowMultiple: q.allowMultiple == true)
                })
            send(.questionRequest(sessionId: id, payload: payload))
        } else if let rid = lastQuestionReq.removeValue(forKey: id) {
            send(.questionResolved(sessionId: id, requestId: rid))
        }
    }

    // MARK: decision

    private func applyDecision(sessionId: String, requestId: Int, optionId: String, persistScope: String?) {
        guard let session = provider.session(for: sessionId),
              let policy = provider.permissionPolicy(for: sessionId),
              let pending = session.transcript.pendingPermission,
              Self.requestIdInt(pending.id) == requestId          // first-wins guard
        else { return }
        guard let option = pending.params.options.first(where: { $0.optionId == optionId }) else { return }

        // Mirror the local SwiftUI prompt's mapping so remote and local
        // decisions log identically (ACPPermissionPrompt.handle).
        let decision: ACPPermissionDecision = option.kind.hasPrefix("allow") ? .allow : .deny
        let scope: ACPPermissionScopeKind?
        if let persistScope {
            scope = persistScope == "session" ? .session
                  : (persistScope == "project" ? .project : nil)
        } else {
            switch option.kind {
            case "allow_once", "reject_once":     scope = nil
            case "allow_always", "reject_always": scope = .project
            default:                              scope = .session
            }
        }

        // Same scopeKey derivation as ACPTabView.scopeKey(for:).
        let scopeKey = Self.scopeKey(for: pending.params)
        policy.userDecided(scopeKey: scopeKey, optionId: optionId, decision: decision, persistScope: scope)
        lastPermissionReq[sessionId] = nil
        send(.permissionResolved(sessionId: sessionId, requestId: requestId))
    }

    private func applyQuestionAnswer(sessionId: String, requestId: Int, answers: [RemoteQuestionAnswer]) {
        guard let session = provider.session(for: sessionId),
              let pending = session.transcript.pendingQuestion,
              Self.requestIdInt(pending.id) == requestId          // first-wins guard
        else { return }
        // Require a non-empty selection for every question and order each by the
        // question's option order — the same completeness rule the local prompt
        // enforces (ACPQuestionPrompt.answeredResponse). Ignore malformed/partial
        // input rather than resuming the agent with vacuous answers.
        let selectionByQuestion = Dictionary(answers.map { ($0.questionId, Set($0.selectedOptionIds)) },
                                             uniquingKeysWith: { $1 })
        var acpAnswers: [ACPQuestionAnswer] = []
        for question in pending.params.questions {
            let selected = selectionByQuestion[question.id] ?? []
            // Keep only ids that are real options for this question. If none
            // survive (empty, or unknown ids from a stale/malicious client),
            // treat the answer as incomplete rather than resuming the agent with
            // a vacuous selection.
            let ordered = question.options.map(\.id).filter { selected.contains($0) }
            guard !ordered.isEmpty else { return }
            acpAnswers.append(ACPQuestionAnswer(questionId: question.id, selectedOptionIds: ordered))
        }
        provider.answerQuestion(for: sessionId, .init(outcome: .answered(answers: acpAnswers)))
        lastQuestionReq[sessionId] = nil
        send(.questionResolved(sessionId: sessionId, requestId: requestId))
    }

    // MARK: serialization helpers

    static func stateString(_ s: ACPSession.StreamingState) -> String {
        switch s {
        case .idle: return "idle"
        case .sending, .streaming: return "streaming"
        case .awaitingPermission: return "awaitingPermission"
        case .awaitingInput: return "awaitingInput"
        }
    }

    /// Extracts the integer request id. In practice `pendingPermission.id` is
    /// always `.number(0)` (set by ACPPermissionPolicy), so the first-wins guard
    /// distinguishes "this prompt is still pending" from "already resolved"
    /// (pending goes nil) rather than telling sequential requests apart — which
    /// is fine because the agent blocks on each prompt before issuing the next.
    static func requestIdInt(_ id: JSONRPCID) -> Int {
        if case .number(let n) = id { return n }
        return -1
    }

    /// scopeKey used to record a permission decision. Replicates the exact
    /// derivation in `ACPTabView.scopeKey(for:)` so remote and local decisions
    /// land on the same key in `permission_decisions`.
    static func scopeKey(for params: ACPPermissionRequestParams) -> String {
        "tool:\(params.toolCall.title ?? params.toolCall.toolCallId)"
    }

    /// Maps a live ACPMessage to the wire DTO. Simple kinds carry `text`;
    /// structured kinds carry a JSON blob the web client renders specially.
    ///
    /// The id is the message's POSITION, not `ACPMessage.stableId`: a read-only
    /// mirror re-decodes the transcript on every refresh, minting fresh UUIDs
    /// each time (`ACPMessageWire.toMessage`), so the per-message id is not
    /// stable across our full re-snapshots. Position is — the Nth message stays
    /// the Nth — so the client can upsert idempotently instead of accumulating
    /// duplicate copies of the whole transcript on each refresh.
    static func toWire(_ message: ACPMessage, index: Int) -> RemoteWireMessage {
        let sid = "m\(index)"
        switch message {
        case .user(_, let text, _):
            return .init(stableId: sid, kind: "user", text: text, json: nil)
        case .agent(_, let streaming):
            return .init(stableId: sid, kind: "agent", text: streaming.value, json: nil)
        case .thought(_, let streaming):
            return .init(stableId: sid, kind: "thought", text: streaming.value, json: nil)
        case .systemNotice(_, let text):
            return .init(stableId: sid, kind: "systemNotice", text: text, json: nil)
        case .toolCall(let call):
            return .init(stableId: sid, kind: "toolCall", text: nil, json: Self.encodeJSON(call))
        case .fileEdit(_, let edit):
            return .init(stableId: sid, kind: "fileEdit", text: nil, json: Self.encodeJSON(edit))
        case .plan(_, let items):
            return .init(stableId: sid, kind: "plan", text: nil, json: Self.encodeJSON(items))
        }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
