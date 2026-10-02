import Foundation

struct RemoteSessionKey: Codable, Equatable, Sendable {
    let worktreePath: String
    let agentId: String
    let remoteSessionId: String?
}

struct RemoteSessionOwner: Codable, Equatable, Sendable {
    let serverId: String
    let instanceId: String
}

struct RemoteSessionFence: Codable, Equatable, Sendable {
    let recordId: String
    let token: String
}

struct RemoteSessionLease: Codable, Equatable, Sendable {
    let recordId: String
    let key: RemoteSessionKey
    let procId: String
    let owner: RemoteSessionOwner?
    let status: String
    let isFresh: Bool
    let revision: Int64
}

struct RemoteSessionClaimParams: Codable, Equatable, Sendable {
    let key: RemoteSessionKey
    let owner: RemoteSessionOwner
    let proposedProcId: String
    let requestedToken: String
    var previousFence: RemoteSessionFence? = nil
}

struct RemoteSessionClaimResult: Codable, Equatable, Sendable {
    let lease: RemoteSessionLease
    let fence: RemoteSessionFence?
}

struct RemoteSessionBindParams: Codable, Equatable, Sendable {
    let fence: RemoteSessionFence
    let remoteSessionId: String
}

struct RemoteSessionHeartbeatParams: Codable, Equatable, Sendable {
    let fence: RemoteSessionFence
    let status: String
}

struct RemoteSessionObserveParams: Codable, Equatable, Sendable {
    let key: RemoteSessionKey
}

struct RemoteSessionObserveResult: Codable, Equatable, Sendable {
    let lease: RemoteSessionLease?
}

struct RemoteSessionReleaseParams: Codable, Equatable, Sendable {
    let fence: RemoteSessionFence
}

struct RemoteSessionMutationResult: Codable, Equatable, Sendable {
    let ok: Bool
}

struct RemoteSessionReplicaEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case metadata, message, subagent, queue, fork, relationship
    }
    let kind: Kind
    let key: String
    let payload: Data?
    let revision: Int64
}

struct RemoteSessionPublishParams: Codable, Equatable, Sendable {
    let fence: RemoteSessionFence
    let batchId: String
    let entries: [RemoteSessionReplicaEntry]
    let status: String
}

struct RemoteSessionPublishResult: Codable, Equatable, Sendable {
    let revision: Int64
}

struct RemoteSessionReadParams: Codable, Equatable, Sendable {
    let recordId: String
    let afterRevision: Int64
    let pageToken: String?
}

struct RemoteSessionReadResult: Codable, Equatable, Sendable {
    let cutoffRevision: Int64
    let entries: [RemoteSessionReplicaEntry]
    let nextPageToken: String?
}

struct RemoteSessionCancelReadParams: Codable, Equatable, Sendable {
    let pageToken: String
}

struct RemoteSessionUnavailable: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    static let helperRequired = Self(message: "Update and enable the Alas helper on this SSH host to coordinate this session.")
    static let ownershipLost = Self(message: "This SSH session is owned by another Alas instance.")
}

extension Error {
    var isRemoteSessionLeaseLoss: Bool {
        guard let helperError = self as? RemoteHelperClientError, case let .jsonrpc(error) = helperError else { return false }
        return error.code == -32081
    }
}
