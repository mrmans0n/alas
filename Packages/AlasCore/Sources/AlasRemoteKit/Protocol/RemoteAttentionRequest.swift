import Foundation

/// An open item of the Mac's attention inbox, as the phone lists it.
public struct RemoteAttentionItem: Codable, Equatable, Identifiable, Sendable {
    /// The Mac's attention event id, which a dismissal names.
    public let id: UUID
    /// `AttentionKind`, e.g. runScriptFailure, conflicts or agentFailed.
    public let kind: String
    public let title: String
    public let body: String?
    public let project: String
    public let branch: String
    public let occurredAt: Date
    /// The session the item opens, when it is about one.
    public let sessionID: String?

    public init(id: UUID, kind: String, title: String, body: String?, project: String, branch: String,
                occurredAt: Date, sessionID: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.project = project
        self.branch = branch
        self.occurredAt = occurredAt
        self.sessionID = sessionID
    }
}

/// The attention verbs as host-protocol messages (`host.attention.phone.v1`),
/// for a client that carries them as `OpaqueHostMessage`.
public enum RemoteAttentionRequest {
    public static func list(id: Int) -> OpaqueHostMessage {
        RemoteGitRequest.envelope(id: id, ["attention": [:] as [String: Any]])
    }

    /// Answered as a git action is: see `RemoteGitRequest.reply(to:in:)`.
    public static func dismiss(id: Int, eventIDs: [UUID]) -> OpaqueHostMessage {
        RemoteGitRequest.envelope(id: id, ["dismissAttention": ["eventIDs": eventIDs.map(\.uuidString)]])
    }

    public static func items(replying id: Int, in message: OpaqueHostMessage) -> [RemoteAttentionItem]? {
        guard let object = try? JSONSerialization.jsonObject(with: message.json) as? [String: Any],
              let response = object["response"] as? [String: Any], response["id"] as? Int == id,
              let raw = ((response["result"] as? [String: Any])?["attention"] as? [String: Any])?["items"],
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode([RemoteAttentionItem].self, from: data)
    }
}
