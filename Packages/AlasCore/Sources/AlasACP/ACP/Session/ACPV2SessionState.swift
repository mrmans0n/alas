import Foundation

/// One synchronous owner of v2 canonical state. Effects describe decisions only;
/// callers retain transport, projection, persistence, and delivery ownership.
public struct ACPV2SessionState: Sendable {
    public typealias Context = ACPV2MessageTranscript.Context

    public enum Key: Hashable, Sendable {
        case message(ACPV2MessageTranscript.Key)
        case toolCall(String), plan(String), terminal(String)
    }

    public enum Effect: Equatable, Sendable {
        case message(ACPV2MessageTranscript.Effect)
        case activity(ACPV2ActivityState.Effect)
        case lifecycle(ACPSessionLifecycle.Effect)
    }

    public struct Reduction: Equatable, Sendable {
        public enum Disposition: Equatable, Sendable { case applied, unhandled, staleContext }
        public let event: ACPV2SessionUpdateEnvelope
        public let disposition: Disposition
        public let effects: [Effect]
    }

    public struct StateObservation: Equatable, Sendable {
        public let event: ACPV2SessionUpdateEnvelope
        public let source: ACPSessionLifecycle.StateSource
    }

    public struct SubmissionReduction: Equatable, Sendable {
        public enum Disposition: Equatable, Sendable {
            case registered, accepted, rejected, unchanged, unmatched, conflict, staleContext
        }
        public let response: ACPV2PromptAccepted?
        public let disposition: Disposition
        public let effects: [Effect]
    }

    public enum ApplicationError: Error, Equatable, Sendable { case invalidSetupDefault }

    public let context: Context
    public private(set) var transcript: ACPV2MessageTranscript
    public private(set) var activity: ACPV2ActivityState
    public private(set) var lifecycle = ACPSessionLifecycle(protocolVersion: .v2)
    public private(set) var order: [Key] = []
    public private(set) var latestStateObservation: StateObservation?

    public init(context: Context) {
        self.context = context
        self.transcript = ACPV2MessageTranscript(context: context)
        self.activity = ACPV2ActivityState(context: context)
    }

    @discardableResult
    public mutating func apply(_ event: ACPV2SessionUpdateEnvelope,
        source: ACPSessionLifecycle.StateSource, context: Context) throws -> Reduction {
        guard context == self.context, event.sessionID == context.sessionID else {
            return Reduction(event: event, disposition: .staleContext, effects: [])
        }
        if source == .setupDefault {
            guard case .state(let update) = event.payload, update.state == .idle else {
                throw ApplicationError.invalidSetupDefault
            }
        }
        let effects: [Effect]
        switch event.payload {
        case .message:
            let start = transcript.messages.count
            effects = transcript.apply(event, context: context).effects.map(Effect.message)
            order += transcript.messages.dropFirst(start).map { .message($0.key) }
        case .toolCall, .toolContentChunk, .plan, .terminal, .terminalOutputChunk:
            let start = activity.order.count
            effects = activity.apply(event, context: context).effects.map(Effect.activity)
            order += activity.order.dropFirst(start).map { key in
                switch key {
                case .toolCall(let id): .toolCall(id)
                case .plan(let id): .plan(id)
                case .terminal(let id): .terminal(id)
                }
            }
        case .state(let update):
            if source == .setupDefault, latestStateObservation != nil {
                return Reduction(event: event, disposition: .applied, effects: [])
            }
            effects = lifecycle.update(update, source: source).map(Effect.lifecycle)
            latestStateObservation = StateObservation(event: event, source: source)
        case .unhandled:
            return Reduction(event: event, disposition: .unhandled, effects: [])
        }
        return Reduction(event: event, disposition: .applied, effects: effects)
    }

    @discardableResult
    public mutating func register(requestID: Int, localRowID: UUID, context: Context) -> SubmissionReduction {
        guard context == self.context else {
            return SubmissionReduction(response: nil, disposition: .staleContext, effects: [])
        }
        let disposition: SubmissionReduction.Disposition
        switch transcript.register(requestID: requestID, localRowID: localRowID, context: context) {
        case .registered:
            lifecycle.submit(requestID)
            disposition = .registered
        case .unchanged: disposition = .unchanged
        default: disposition = .conflict
        }
        return SubmissionReduction(response: nil, disposition: disposition, effects: [])
    }

    @discardableResult
    public mutating func accept(requestID: Int, response: ACPV2PromptAccepted, context: Context) -> SubmissionReduction {
        guard context == self.context else {
            return SubmissionReduction(response: response, disposition: .staleContext, effects: [])
        }
        guard let current = lifecycle.submission(requestID) else {
            return SubmissionReduction(response: response, disposition: .unmatched, effects: [])
        }
        switch current {
        case .accepted(let messageID):
            return SubmissionReduction(response: response,
                disposition: messageID == response.messageID ? .unchanged : .conflict, effects: [])
        case .rejected:
            return SubmissionReduction(response: response, disposition: .conflict, effects: [])
        case .pending, .uncertain: break
        }
        // Validate on trial values. A conflicting binding cannot leave either
        // child committed while the other rejects this response.
        var nextTranscript = transcript
        let correlation = nextTranscript.accept(requestID: requestID, response: response, context: context)
        var effects: [Effect] = []
        switch correlation {
        case .bound, .unchanged: break
        case .reconciled(let key, let row):
            guard let message = nextTranscript.message(for: key) else {
                return SubmissionReduction(response: response, disposition: .conflict, effects: [])
            }
            effects = [.message(.reconcile(key: key, localRowID: row)), .message(.messageChanged(message))]
        default:
            return SubmissionReduction(response: response, disposition: .conflict, effects: [])
        }
        var nextLifecycle = lifecycle
        let accepted = nextLifecycle.accept(requestID, response: response)
        guard !accepted.isEmpty else {
            return SubmissionReduction(response: response, disposition: .conflict, effects: [])
        }
        transcript = nextTranscript
        lifecycle = nextLifecycle
        effects += accepted.map(Effect.lifecycle)
        return SubmissionReduction(response: response, disposition: .accepted, effects: effects)
    }

    @discardableResult
    public mutating func reject(requestID: Int, context: Context) -> SubmissionReduction {
        guard context == self.context else {
            return SubmissionReduction(response: nil, disposition: .staleContext, effects: [])
        }
        guard let current = lifecycle.submission(requestID) else {
            return SubmissionReduction(response: nil, disposition: .unmatched, effects: [])
        }
        switch current {
        case .accepted: return SubmissionReduction(response: nil, disposition: .conflict, effects: [])
        case .rejected: return SubmissionReduction(response: nil, disposition: .unchanged, effects: [])
        case .pending, .uncertain:
            return SubmissionReduction(response: nil, disposition: .rejected,
                effects: lifecycle.reject(requestID).map(Effect.lifecycle))
        }
    }

    /// Retain insertion evidence and last observation. Losing the stream is not
    /// evidence of upstream rejection, process exit, or completed foreground work.
    @discardableResult
    public mutating func loseObservation(context: Context) -> [Effect] {
        guard context == self.context else { return [] }
        return lifecycle.loseObservation().map(Effect.lifecycle)
    }
}
