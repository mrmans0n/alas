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

/// An outcome waiting for the delegating machine to collect it. `seq` is the
/// collection cursor; `messageId` is the stable outcome/blocker id.
public struct ACPPeerOutboxEntry: Codable, Equatable, Sendable {
    public let seq: Int64
    public let messageId: String
    public let childSessionId: String
    public let prompt: String
    public let kind: ACPDelegatedMessageKind
    public let createdAt: Int64

    public init(seq: Int64, messageId: String, childSessionId: String, prompt: String, kind: ACPDelegatedMessageKind, createdAt: Int64) {
        self.seq = seq
        self.messageId = messageId
        self.childSessionId = childSessionId
        self.prompt = prompt
        self.kind = kind
        self.createdAt = createdAt
    }
}
