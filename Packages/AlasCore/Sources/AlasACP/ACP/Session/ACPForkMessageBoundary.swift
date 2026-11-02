import CryptoKit
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct ACPForkMessageBoundary: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case user
        case agent
    }

    public let stableID: String
    public let kind: Kind

    public init(stableID: String, kind: Kind) {
        self.stableID = stableID
        self.kind = kind
    }
}

public enum ACPSessionForkCreationPhase: String, Codable, Equatable, Sendable {
    case negotiatingNative
    case ready
}

public enum ACPSessionForkMechanism: String, Codable, Equatable, Sendable {
    case nativeACP
    case transcriptTransfer
}

public struct ACPSessionForkRecord: Equatable, Sendable {
    public let targetSessionID: String
    public let sourceSessionID: String
    public let sourceAgentID: String
    public let sourceBoundarySequence: Int64
    public let inheritedMessageCount: Int
    public var phase: ACPSessionForkCreationPhase
    public var mechanism: ACPSessionForkMechanism?
    public var contextDeliveryPending: Bool
    public var via: ACPSessionForkVia? = nil
    public var forkPoint: ACPSessionForkPoint? = nil

    public init(targetSessionID: String, sourceSessionID: String, sourceAgentID: String, sourceBoundarySequence: Int64, inheritedMessageCount: Int, phase: ACPSessionForkCreationPhase, mechanism: ACPSessionForkMechanism? = nil, contextDeliveryPending: Bool, via: ACPSessionForkVia? = nil, forkPoint: ACPSessionForkPoint? = nil) {
        self.targetSessionID = targetSessionID
        self.sourceSessionID = sourceSessionID
        self.sourceAgentID = sourceAgentID
        self.sourceBoundarySequence = sourceBoundarySequence
        self.inheritedMessageCount = inheritedMessageCount
        self.phase = phase
        self.mechanism = mechanism
        self.contextDeliveryPending = contextDeliveryPending
        self.via = via
        self.forkPoint = forkPoint
    }
}

/// The message a fork was cut at, and what the agent said about it.
/// `outcome` stays nil until the agent has answered.
public struct ACPSessionForkPoint: Codable, Equatable, Sendable {
    public enum Outcome: Codable, Equatable, Sendable {
        case matched(ACPForkPointEcho)
        case unmatched(ACPForkPointFailure)
    }

    public let target: ACPForkPointTarget
    public let boundary: ACPForkPointBoundary
    public var outcome: Outcome?

    public init(target: ACPForkPointTarget, boundary: ACPForkPointBoundary, outcome: Outcome? = nil) {
        self.target = target
        self.boundary = boundary
        self.outcome = outcome
    }
}

/// The Alas feature that created a fork, when it wasn't a plain fork.
public enum ACPSessionForkVia: String, Equatable, Sendable {
    case btw
}

public enum ACPSessionForkCandidate: Equatable, Sendable {
    case native
    /// A native fork cut at an earlier agent message through the agent's
    /// `forkPoint` extension.
    case nativeAtMessage(ACPForkPointTarget)
    case transcript
}

public enum ACPSessionForkCandidatePolicy: Sendable {
    public static func candidate(
        sourceAgentID: String,
        targetAgentID: String,
        boundaryIsRemoteHead: Bool,
        sourceRemoteSessionID: String?,
        forkCapability: Bool?,
        forkPoint: ACPForkPointCapability?,
        historicalTarget: ACPForkPointTarget?
    ) -> ACPSessionForkCandidate {
        guard sourceAgentID == targetAgentID,
              sourceRemoteSessionID?.isEmpty == false,
              forkCapability != false
        else { return .transcript }

        if boundaryIsRemoteHead { return .native }
        if forkPoint != nil, let historicalTarget { return .nativeAtMessage(historicalTarget) }
        return .transcript
    }
}

public struct ACPSessionForkConversationMessage: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user
        case agent
    }

    public let role: Role
    public let text: String
    /// The agent's own id for an agent message; nil for user messages.
    public let messageId: String?

    public init(role: Role, text: String, messageId: String? = nil) {
        self.role = role
        self.text = text
        self.messageId = messageId
    }
}

/// Checks that the agent forked where it was asked to, from the `forkPoint`
/// its `session/fork` result echoes.
public enum ACPForkPointVerifier: Sendable {
    public static func verify(
        echo: ACPForkPointEcho?,
        target: ACPForkPointTarget,
        boundary: ACPForkPointBoundary,
        laterSourceItemIDs: Set<String>
    ) -> Result<ACPForkPointEcho, ACPForkPointFailure> {
        guard let echo else { return .failure(.missingEcho) }
        guard echo.boundary == boundary else { return .failure(.mismatchedEcho) }
        let later = Set(laterSourceItemIDs.map(unsegmented))
        switch echo.matchedBy {
        case .id:
            guard unsegmented(echo.messageId) == unsegmented(target.messageId) else {
                return .failure(.mismatchedEcho)
            }
        case .fingerprint:
            // A fingerprint can also match an equal message after the target.
            guard !later.contains(unsegmented(echo.messageId)) else { return .failure(.mismatchedEcho) }
        }
        if boundary == .turn {
            guard echo.turnId?.isEmpty == false,
                  let lastItemId = echo.lastItemId, !lastItemId.isEmpty,
                  !later.contains(unsegmented(lastItemId))
            else { return .failure(.mismatchedEcho) }
        }
        return .success(echo)
    }

    /// An adapter may address part of a message as `<id>:segment:<n>`.
    private static func unsegmented(_ id: String) -> String {
        guard let range = id.range(of: ":segment:", options: .backwards),
              !id[range.upperBound...].isEmpty,
              id[range.upperBound...].allSatisfy({ $0.isASCII && $0.isNumber })
        else { return id }
        return String(id[..<range.lowerBound])
    }
}

public enum ACPSessionForkSnapshotError: Error, Equatable, Sendable {
    case boundaryNotFound
    case transcriptMismatch
}

package struct CopiedTextPayload: Codable {
    let messageId: String?
    let text: String

    public init(messageId: String?, text: String) {
        self.messageId = messageId
        self.text = text
    }
}

public enum ACPSessionForkMergeError: Error, Equatable, LocalizedError, Sendable {
    case forkUnavailable
    case forkBusy
    case noConversation
    case sourceUnavailable
    case sourceReadOnly
    case sourceReadUnavailable
    case deliveryFailed
    case archiveFailed

    public var errorDescription: String? {
        switch self {
        case .forkUnavailable: "This fork is not available to merge."
        case .forkBusy: "Wait for the fork's pending turns to finish before merging."
        case .noConversation: "There is no conversation after the fork point to merge."
        case .sourceUnavailable: "The source session is missing or archived."
        case .sourceReadOnly: "The source session is read-only or controlled by another instance."
        case .sourceReadUnavailable: "Connect the source with the built-in Alas server to merge this longer conversation. The fork was kept."
        case .deliveryFailed: "Could not queue the merge in the source session. The fork was kept."
        case .archiveFailed: "The digest was queued, but the fork could not be archived."
        }
    }
}
