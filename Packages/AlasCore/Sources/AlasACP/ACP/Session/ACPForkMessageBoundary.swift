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

    public init(targetSessionID: String, sourceSessionID: String, sourceAgentID: String, sourceBoundarySequence: Int64, inheritedMessageCount: Int, phase: ACPSessionForkCreationPhase, mechanism: ACPSessionForkMechanism? = nil, contextDeliveryPending: Bool, via: ACPSessionForkVia? = nil) {
        self.targetSessionID = targetSessionID
        self.sourceSessionID = sourceSessionID
        self.sourceAgentID = sourceAgentID
        self.sourceBoundarySequence = sourceBoundarySequence
        self.inheritedMessageCount = inheritedMessageCount
        self.phase = phase
        self.mechanism = mechanism
        self.contextDeliveryPending = contextDeliveryPending
        self.via = via
    }
}

/// The Alas feature that created a fork, when it wasn't a plain fork.
public enum ACPSessionForkVia: String, Equatable, Sendable {
    case btw
}

public enum ACPSessionForkCandidate: Equatable, Sendable {
    case native
    case transcript
}

public enum ACPSessionForkCandidatePolicy: Sendable {
    public static func candidate(
        sourceAgentID: String,
        targetAgentID: String,
        boundaryIsRemoteHead: Bool,
        sourceRemoteSessionID: String?,
        forkCapability: Bool?
    ) -> ACPSessionForkCandidate {
        guard sourceAgentID == targetAgentID,
              boundaryIsRemoteHead,
              sourceRemoteSessionID?.isEmpty == false,
              forkCapability != false
        else { return .transcript }

        return .native
    }
}

public struct ACPSessionForkConversationMessage: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user
        case agent
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
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
