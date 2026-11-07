import Foundation

/// The parent value a delegated child carries on the machine that runs it when
/// the delegating session lives on a paired Mac. The part after the prefix is
/// the paired peer's server id.
public enum ACPPeerParent {
    public static let prefix = "peer:"

    public static func sentinel(serverId: String) -> String {
        prefix + serverId
    }

    /// The peer's server id, or nil when `parentSessionId` is a real session.
    public static func serverId(from parentSessionId: String) -> String? {
        guard parentSessionId.hasPrefix(prefix) else { return nil }
        let id = String(parentSessionId.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}

/// How far the delegating machine has collected a peer's outbox: `seq` counts
/// in the peer's store `store`, nil until the peer reported one.
public struct ACPPeerCursorPosition: Equatable, Sendable {
    public let seq: Int64
    public let store: String?

    public init(seq: Int64, store: String?) {
        self.seq = seq
        self.store = store
    }
}

/// An outcome waiting for the delegating machine to collect it. `seq` is the
/// collection cursor; `messageId` is the stable outcome/blocker id.
public struct ACPPeerOutboxEntry: Codable, Equatable, Sendable {
    public let seq: Int64
    public let messageId: String
    public let childSessionId: String
    public let prompt: String
    public let kind: ACPDelegatedMessageKind
    public let createdAt: Int64

    /// When the turn this outcome ended started, epoch milliseconds by the
    /// target's clock: `outcome-<child>-<startedAt>`. Nil for anything else,
    /// such as `outcome-<child>-failed`.
    public var turnStartedAt: Int64? {
        let prefix = "outcome-\(childSessionId)-"
        guard messageId.hasPrefix(prefix) else { return nil }
        return Int64(messageId.dropFirst(prefix.count))
    }

    public init(seq: Int64, messageId: String, childSessionId: String, prompt: String, kind: ACPDelegatedMessageKind, createdAt: Int64) {
        self.seq = seq
        self.messageId = messageId
        self.childSessionId = childSessionId
        self.prompt = prompt
        self.kind = kind
        self.createdAt = createdAt
    }
}

/// Where a child a paired Mac asked for runs on this one.
public enum ACPPeerChildTarget: Equatable, Sendable {
    case worktree(path: String)
    /// `expectedBaseSHA`, when set, is what `base` must be at on the remote.
    case newWorktree(branch: String, base: String, expectedBaseSHA: String?)
}

/// A paired Mac's request to start a delegated child here. `autoRun` is
/// already what this Mac allows for that peer. `childID` is the requester's,
/// which makes a repeated request find the same child.
public struct ACPPeerChildStart: Sendable {
    public let childID: String
    public let peerServerId: String
    public let projectID: String
    public let target: ACPPeerChildTarget
    public let agentID: String
    public let modelSelection: ACPDelegatedModelSelection?
    public let role: String?
    public let autoRun: Bool
    public let prompt: String

    public init(
        childID: String,
        peerServerId: String,
        projectID: String,
        target: ACPPeerChildTarget,
        agentID: String,
        modelSelection: ACPDelegatedModelSelection?,
        role: String?,
        autoRun: Bool,
        prompt: String
    ) {
        self.childID = childID
        self.peerServerId = peerServerId
        self.projectID = projectID
        self.target = target
        self.agentID = agentID
        self.modelSelection = modelSelection
        self.role = role
        self.autoRun = autoRun
        self.prompt = prompt
    }
}

public enum ACPPeerStartResult: Equatable, Sendable {
    /// `state` is an `ACPOrchestrationPublicState` raw value. A child that
    /// fails from here on reports that through the outbox.
    case started(sessionId: String, state: String)
    case refused(String)
}
