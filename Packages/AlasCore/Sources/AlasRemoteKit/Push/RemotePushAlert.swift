import Foundation

/// What a pushed alert says once the phone has seen the request itself. The
/// wording matches the Inbox cards, so the lock screen and the card agree.
public enum RemotePushAlert {
    /// The tool name a host puts on a visual aid's permission, in place of the
    /// agent's own text.
    public static let visualAidToolName = "Visual aid"
    public static let maxBodyLength = 178

    /// Nil for anything that is not a request. `isPermission` is true only for
    /// a permission that is not a visual aid: those get Allow/Deny actions.
    public static func content<C, S>(
        for message: RemoteServerMessageOf<C, S>, sessionTitle: String?
    ) -> (title: String, body: String, isPermission: Bool)? where C: Codable & Equatable & Sendable, S: Codable & Equatable & Sendable {
        let body: String
        var isPermission = false
        switch message {
        case .permissionRequest(_, let payload):
            if payload.toolName == visualAidToolName {
                body = "Has a visual for you"
            } else {
                body = "Wants to run \(payload.title ?? payload.toolName)"
                isPermission = true
            }
        case .questionRequest(_, let payload):
            body = payload.questions.first?.prompt ?? payload.title ?? "The agent has a question"
        case .planRequest:
            body = "Plan ready for review"
        case .elicitationRequest(_, let payload):
            body = payload.message
        default:
            return nil
        }
        let title = sessionTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Alas"
        let text = body.count > maxBodyLength ? String(body.prefix(maxBodyLength - 1)) + "…" : body
        return (title, text, isPermission)
    }
}
