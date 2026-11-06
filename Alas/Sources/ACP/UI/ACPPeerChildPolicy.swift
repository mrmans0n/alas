import Foundation

/// Decisions for the row that stands for a child running on another Mac.
/// The child has no session here, so its row can only open the session in the
/// peer view, and that works only while the Mac is connected and lists it.
enum ACPPeerChildPolicy {
    enum Destination: Equatable {
        case open(federatedSessionID: String)
        /// Stay where we are and say why the session cannot be opened.
        case explain(String)
    }

    static func label(macName: String) -> String {
        "on \(macName)"
    }

    static func destination(
        macName: String, serverId: String, childSessionId: String,
        macIsConnected: Bool, sessionIsListed: Bool
    ) -> Destination {
        guard macIsConnected else {
            return .explain("\(macName) is not connected right now. Open this session once it is back.")
        }
        guard sessionIsListed else {
            return .explain("\(macName) has not listed this session yet. Try again in a moment.")
        }
        return .open(federatedSessionID: RemoteFederatedSessionID.compose(serverId: serverId, sessionId: childSessionId))
    }

    /// Body of the notification for a child blocked on a person.
    static func blockedNotificationBody(macName: String) -> String {
        "A session on \(macName) is waiting for a permission, answer or plan."
    }
}
