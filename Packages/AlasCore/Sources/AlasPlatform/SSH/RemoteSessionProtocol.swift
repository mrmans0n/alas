import Foundation
import AlasFoundation
import AlasModel

public struct RemoteSessionKey: Codable, Equatable, Sendable {
    public let worktreePath: String
    public let agentId: String
    public let remoteSessionId: String?

    public init(worktreePath: String, agentId: String, remoteSessionId: String?) {
        self.worktreePath = worktreePath
        self.agentId = agentId
        self.remoteSessionId = remoteSessionId
    }
}

public struct RemoteSessionOwner: Codable, Equatable, Sendable {
    public let serverId: String
    public let instanceId: String

    public init(serverId: String, instanceId: String) {
        self.serverId = serverId
        self.instanceId = instanceId
    }
}

public struct RemoteSessionFence: Codable, Equatable, Sendable {
    public let recordId: String
    public let token: String

    public init(recordId: String, token: String) {
        self.recordId = recordId
        self.token = token
    }
}

public struct RemoteSessionLease: Codable, Equatable, Sendable {
    public let recordId: String
    public let key: RemoteSessionKey
    public let procId: String
    public let owner: RemoteSessionOwner?
    public let status: String
    public let isFresh: Bool
    public let revision: Int64

    public init(recordId: String, key: RemoteSessionKey, procId: String, owner: RemoteSessionOwner?, status: String, isFresh: Bool, revision: Int64) {
        self.recordId = recordId
        self.key = key
        self.procId = procId
        self.owner = owner
        self.status = status
        self.isFresh = isFresh
        self.revision = revision
    }
}

public struct RemoteSessionClaimParams: Codable, Equatable, Sendable {
    public let key: RemoteSessionKey
    public let owner: RemoteSessionOwner
    public let proposedProcId: String
    public let requestedToken: String
    public var previousFence: RemoteSessionFence? = nil

    public init(key: RemoteSessionKey, owner: RemoteSessionOwner, proposedProcId: String, requestedToken: String, previousFence: RemoteSessionFence? = nil) {
        self.key = key
        self.owner = owner
        self.proposedProcId = proposedProcId
        self.requestedToken = requestedToken
        self.previousFence = previousFence
    }
}

public struct RemoteSessionClaimResult: Codable, Equatable, Sendable {
    public let lease: RemoteSessionLease
    public let fence: RemoteSessionFence?

    public init(lease: RemoteSessionLease, fence: RemoteSessionFence?) {
        self.lease = lease
        self.fence = fence
    }
}

public struct RemoteSessionBindParams: Codable, Equatable, Sendable {
    public let fence: RemoteSessionFence
    public let remoteSessionId: String

    public init(fence: RemoteSessionFence, remoteSessionId: String) {
        self.fence = fence
        self.remoteSessionId = remoteSessionId
    }
}

public struct RemoteSessionHeartbeatParams: Codable, Equatable, Sendable {
    public let fence: RemoteSessionFence
    public let status: String

    public init(fence: RemoteSessionFence, status: String) {
        self.fence = fence
        self.status = status
    }
}

public struct RemoteSessionObserveParams: Codable, Equatable, Sendable {
    public let key: RemoteSessionKey

    public init(key: RemoteSessionKey) {
        self.key = key
    }
}

public struct RemoteSessionObserveResult: Codable, Equatable, Sendable {
    public let lease: RemoteSessionLease?

    public init(lease: RemoteSessionLease?) {
        self.lease = lease
    }
}

public struct RemoteSessionReleaseParams: Codable, Equatable, Sendable {
    public let fence: RemoteSessionFence

    public init(fence: RemoteSessionFence) {
        self.fence = fence
    }
}

public struct RemoteSessionMutationResult: Codable, Equatable, Sendable {
    public let ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

public struct RemoteSessionReplicaEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case metadata, message, subagent, queue, fork, relationship
    }
    public let kind: Kind
    public let key: String
    public let payload: Data?
    public let revision: Int64

    public init(kind: Kind, key: String, payload: Data?, revision: Int64) {
        self.kind = kind
        self.key = key
        self.payload = payload
        self.revision = revision
    }
}

public struct RemoteSessionPublishParams: Codable, Equatable, Sendable {
    public let fence: RemoteSessionFence
    public let batchId: String
    public let entries: [RemoteSessionReplicaEntry]
    public let status: String

    public init(fence: RemoteSessionFence, batchId: String, entries: [RemoteSessionReplicaEntry], status: String) {
        self.fence = fence
        self.batchId = batchId
        self.entries = entries
        self.status = status
    }
}

public struct RemoteSessionPublishResult: Codable, Equatable, Sendable {
    public let revision: Int64

    public init(revision: Int64) {
        self.revision = revision
    }
}

public struct RemoteSessionReadParams: Codable, Equatable, Sendable {
    public let recordId: String
    public let afterRevision: Int64
    public let pageToken: String?

    public init(recordId: String, afterRevision: Int64, pageToken: String?) {
        self.recordId = recordId
        self.afterRevision = afterRevision
        self.pageToken = pageToken
    }
}

public struct RemoteSessionReadResult: Codable, Equatable, Sendable {
    public let cutoffRevision: Int64
    public let entries: [RemoteSessionReplicaEntry]
    public let nextPageToken: String?

    public init(cutoffRevision: Int64, entries: [RemoteSessionReplicaEntry], nextPageToken: String?) {
        self.cutoffRevision = cutoffRevision
        self.entries = entries
        self.nextPageToken = nextPageToken
    }
}

public struct RemoteSessionCancelReadParams: Codable, Equatable, Sendable {
    public let pageToken: String

    public init(pageToken: String) {
        self.pageToken = pageToken
    }
}

public struct RemoteSessionUnavailable: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public static let helperRequired = Self(message: "Update and enable the Alas helper on this SSH host to coordinate this session.")
    public static let ownershipLost = Self(message: "This SSH session is owned by another Alas instance.")
    public static let visualRelayRequired = Self(message: "Update the Alas helper on this SSH host to use visual aids.")

    public init(message: String) {
        self.message = message
    }
}

extension Error {
    public var isRemoteSessionLeaseLoss: Bool {
        guard let helperError = self as? RemoteHelperClientError, case let .jsonrpc(error) = helperError else { return false }
        return error.code == -32081
    }
}
