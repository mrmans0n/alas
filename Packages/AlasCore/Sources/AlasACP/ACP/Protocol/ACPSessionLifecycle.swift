import Foundation
import AlasCode
import AlasFoundation

/// Omission, explicit null, malformed values, and future reasons remain distinct.
public struct ACPStopReason: Equatable, Sendable {
    public let rawValue: LSPJSONValue?

    public init(rawValue: LSPJSONValue? = nil) { self.rawValue = rawValue }

    public var v1Result: ACPTurnCompletion.Result {
        switch rawValue {
        case .string("end_turn"): .completed
        case .string("cancelled"): .cancelled
        default: .stopped(self)
        }
    }

    public var summary: String {
        switch rawValue {
        case .string("max_tokens"): "Maximum token limit reached"
        case .string("max_turn_requests"): "Maximum model-request limit reached"
        case .string("refusal"): "Agent declined to continue"
        default: "Outcome unknown"
        }
    }

    public var usageResult: String {
        switch rawValue {
        case .string(let reason) where ["max_tokens", "max_turn_requests", "refusal"].contains(reason): reason
        default: "unknown"
        }
    }
}

public enum ACPForegroundState: Equatable, Sendable {
    case unknown, idle, running, requiresAction
    case unrecognized(String)
}

/// Decisions only. The owner applies effects behind its transport, lease,
/// update-drain, and persistence boundaries. Foreground generations never
/// identify a submission or prove that a model consumed one.
public struct ACPSessionLifecycle: Sendable {
    public enum Submission: Equatable, Sendable {
        case pending, rejected, uncertain
        case accepted(messageID: String)
    }

    public struct ForegroundCompletion: Equatable, Sendable {
        public let generation: Int
        public let result: ACPTurnCompletion.Result

        public init(generation: Int, result: ACPTurnCompletion.Result) {
            self.generation = generation
            self.result = result
        }
    }

    public enum Effect: Equatable, Sendable {
        case accepted(requestID: Int, messageID: String)
        case rejected(requestID: Int)
        case uncertain(requestID: Int)
        case foregroundChanged(ACPForegroundState)
        case foregroundEnded(ForegroundCompletion)
    }

    public enum StateSource: Equatable, Sendable { case live, snapshot, setupDefault }

    public let protocolVersion: ACPProtocolVersion
    public private(set) var foreground: ACPForegroundState = .unknown
    public private(set) var lastForegroundCompletion: ForegroundCompletion?
    private var submissions: [Int: Submission] = [:]
    private var cancellations: Set<Int> = []
    private var generation = 0
    private var intervalOpen = false
    private var observedState = false

    public init(protocolVersion: ACPProtocolVersion) { self.protocolVersion = protocolVersion }

    public func submission(_ requestID: Int) -> Submission? { submissions[requestID] }

    public mutating func submit(_ requestID: Int) {
        if submissions[requestID] == nil { submissions[requestID] = .pending }
    }

    public mutating func requestCancellation(_ requestID: Int) {
        if submissions[requestID] != nil { cancellations.insert(requestID) }
    }

    public mutating func forget(_ requestID: Int) {
        submissions[requestID] = nil
        cancellations.remove(requestID)
    }

    /// V1 closes through its RPC or the existing local Stop path. A forgotten
    /// or already-finished request cannot publish another terminal outcome.
    public mutating func finishV1(_ requestID: Int, result: ACPTurnCompletion.Result) -> ACPTurnCompletion.Result? {
        guard protocolVersion == .v1, submissions[requestID] != nil else { return nil }
        let result: ACPTurnCompletion.Result = cancellations.contains(requestID) ? .cancelled : result
        forget(requestID)
        return result
    }

    public mutating func accept(_ requestID: Int, response: ACPV2PromptAccepted) -> [Effect] {
        guard protocolVersion == .v2,
              submissions[requestID] == .pending || submissions[requestID] == .uncertain else { return [] }
        submissions[requestID] = .accepted(messageID: response.messageID)
        return [.accepted(requestID: requestID, messageID: response.messageID)]
    }

    /// A failed/lost RPC says nothing about insertion or foreground activity.
    public mutating func markSubmissionUncertain(_ requestID: Int) -> [Effect] {
        guard protocolVersion == .v2, submissions[requestID] == .pending else { return [] }
        submissions[requestID] = .uncertain
        return [.uncertain(requestID: requestID)]
    }

    public mutating func reject(_ requestID: Int) -> [Effect] {
        guard protocolVersion == .v2,
              submissions[requestID] == .pending || submissions[requestID] == .uncertain else { return [] }
        submissions[requestID] = .rejected
        return [.rejected(requestID: requestID)]
    }

    public mutating func update(_ update: ACPV2StateUpdate, source: StateSource) -> [Effect] {
        guard protocolVersion == .v2 else { return [] }
        if source == .setupDefault, observedState { return [] }
        observedState = true
        var effects: [Effect] = []
        if foreground != update.state {
            foreground = update.state
            effects.append(.foregroundChanged(foreground))
        }
        switch foreground {
        case .running, .requiresAction:
            if !intervalOpen {
                generation += 1
                intervalOpen = true
            }
        case .idle:
            if intervalOpen, source == .live {
                let completion = ForegroundCompletion(generation: generation, result: update.result)
                lastForegroundCompletion = completion
                effects.append(.foregroundEnded(completion))
            }
            intervalOpen = false
        case .unknown, .unrecognized:
            break
        }
        return effects
    }

    /// Lost observation says nothing about upstream insertion or process life.
    public mutating func loseObservation() -> [Effect] {
        var effects: [Effect] = []
        for id in submissions.keys.sorted() where submissions[id] == .pending {
            submissions[id] = .uncertain
            effects.append(.uncertain(requestID: id))
        }
        if foreground != .unknown { effects.append(.foregroundChanged(.unknown)) }
        foreground = .unknown
        intervalOpen = false
        observedState = false
        return effects
    }
}
