import Foundation
import AlasACP

/// What a failure incident offers the user. The adapter chooses by listing an
/// action on the record; Alas only decides whether the listed action can run here.
public enum ACPFailureAction: String, Equatable, Sendable {
    case retry, login
    case newSession = "new_session"

    /// The button that runs this action.
    public var title: String {
        switch self {
        case .retry: "Retry"
        case .login: "Sign in"
        case .newSession: "New session"
        }
    }
}

/// The live state the action policy reads for one incident.
public struct ACPFailureActionContext: Equatable, Sendable {
    /// This runner still holds the prompt the incident's turn failed on.
    public var isRetryTarget: Bool
    /// The agent can take a prompt: ready, signed in, and not behind a barrier.
    public var agentReady: Bool
    /// A prompt is running or about to, including one being steered.
    public var promptActive: Bool
    public var holdsWriteLease: Bool
    public var isMirror: Bool
    /// Any queue item with `deliveryUncertain`, or a direct turn still marked in flight.
    public var hasUncertainDelivery: Bool
    public var isPeer: Bool

    public init(
        isRetryTarget: Bool, agentReady: Bool, promptActive: Bool, holdsWriteLease: Bool,
        isMirror: Bool, hasUncertainDelivery: Bool, isPeer: Bool
    ) {
        self.isRetryTarget = isRetryTarget
        self.agentReady = agentReady
        self.promptActive = promptActive
        self.holdsWriteLease = holdsWriteLease
        self.isMirror = isMirror
        self.hasUncertainDelivery = hasUncertainDelivery
        self.isPeer = isPeer
    }

    /// A surface that only displays transcripts.
    public static let readOnly = Self(
        isRetryTarget: false, agentReady: false, promptActive: false, holdsWriteLease: false,
        isMirror: false, hasUncertainDelivery: false, isPeer: true)
}

public enum ACPFailureActionPolicy {
    /// Adapter order; unknown and duplicate raw values dropped; category and kind never read.
    public static func visibleActions(rawActions: [String], context: ACPFailureActionContext) -> [ACPFailureAction] {
        var seen: Set<String> = []
        return rawActions.compactMap { raw in
            guard seen.insert(raw).inserted, let action = ACPFailureAction(rawValue: raw),
                  isAvailable(action, context: context)
            else { return nil }
            return action
        }
    }

    private static func isAvailable(_ action: ACPFailureAction, context: ACPFailureActionContext) -> Bool {
        guard !context.isMirror, !context.isPeer else { return false }
        switch action {
        case .retry:
            return context.isRetryTarget && context.agentReady && !context.promptActive
                && context.holdsWriteLease && !context.hasUncertainDelivery
        case .login:
            // Signing in stands the runner down, so it waits for the turn to end.
            return !context.promptActive
        case .newSession:
            return true
        }
    }
}

public struct ACPFailureIncidentPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case error, warningActive, muted }

    public let title: String
    public let details: String?
    public let categoryLabel: String
    public let severityLabel: String
    public let tone: Tone
    public let actions: [ACPFailureAction]

    public static func make(
        _ incident: ACPFailureIncident, context: ACPFailureActionContext, isActiveRetry: Bool
    ) -> Self {
        let record = incident.record
        let isError = record.severity == .error
        return Self(
            title: record.title,
            details: record.details.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
            categoryLabel: categoryLabel(record.knownCategory),
            severityLabel: isError ? "Error" : "Warning",
            tone: isError ? .error : (isActiveRetry ? .warningActive : .muted),
            actions: ACPFailureActionPolicy.visibleActions(rawActions: record.actions, context: context)
        )
    }

    private static func categoryLabel(_ category: ACPSessionFailureRecord.Category) -> String {
        switch category {
        case .connection: "Connection"
        case .access: "Access"
        case .limit: "Limit"
        case .request: "Request"
        case .service: "Service"
        case .unknown: "Other"
        }
    }
}

/// The incident whose failed prompt the runner can still send again. Runtime
/// only, never persisted, so nothing after a relaunch can be a retry target.
public struct ACPRetryableFailure: Equatable, Sendable {
    public let incidentId: String
    public let promptID: Int

    public init(incidentId: String, promptID: Int) {
        self.incidentId = incidentId
        self.promptID = promptID
    }
}
