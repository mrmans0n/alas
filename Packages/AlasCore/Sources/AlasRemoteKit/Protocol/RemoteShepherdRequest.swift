import Foundation

/// What the phone asks of a session's shepherd: `HostShepherdAction`'s raw values.
public enum RemoteShepherdAction: String, Sendable {
    case ship, resume, stop, enableAutoFix, disableAutoFix, enableAutoMerge, disableAutoMerge
}

/// A session's shepherd pill as the host's session list carries it (`HostSessionShepherd`).
/// `badge` is a `ShepherdBadgeState` raw value.
public struct RemoteShepherd: Decodable, Equatable, Sendable {
    public var badge: String
    public var number: String?
    public var tooltip: String
    public var resumable: Bool?
    public var phaseLine: String?
    public var autoFix: Bool?
    public var autoMerge: Bool?

    public init(badge: String, number: String? = nil, tooltip: String = "", resumable: Bool? = nil,
                phaseLine: String? = nil, autoFix: Bool? = nil, autoMerge: Bool? = nil) {
        self.badge = badge
        self.number = number
        self.tooltip = tooltip
        self.resumable = resumable
        self.phaseLine = phaseLine
        self.autoFix = autoFix
        self.autoMerge = autoMerge
    }

    /// Done with: nothing left to stop, resume or switch.
    public var isFinished: Bool { badge == "merged" || badge == "closed" }

    /// What the Mac's peer pill offers (`HostShepherdAction.offered`): Ship without a shepherd,
    /// Resume while it is escalated or paused, Stop until it finished.
    public static func offered(for shepherd: RemoteShepherd?) -> [RemoteShepherdAction] {
        guard let shepherd else { return [.ship] }
        if shepherd.isFinished { return [] }
        return shepherd.resumable == true ? [.resume, .stop] : [.stop]
    }
}

/// Shepherd requests as host-protocol messages, carried like `RemoteGitRequest`'s. A test in
/// AlasCore pins the shapes against `HostClientMessage` and `HostServerMessage`.
public enum RemoteShepherdRequest {
    public static func list(id: Int) -> OpaqueHostMessage {
        encode(["version": RemoteGitRequest.hostProtocolVersion, "id": id, "request": ["listSessions": [String: Any]()]])
    }

    public static func act(id: Int, sessionID: String, action: RemoteShepherdAction) -> OpaqueHostMessage {
        encode(["version": RemoteGitRequest.hostProtocolVersion, "id": id,
                "request": ["shepherdSession": ["sessionID": sessionID, "action": action.rawValue]]])
    }

    /// Session `sessionID`'s shepherd in the session list answering `id`: `.some(nil)` when the host
    /// lists it without one, nil when `message` answers something else or doesn't list the session.
    public static func shepherd(of sessionID: String, replying id: Int, in message: OpaqueHostMessage) -> RemoteShepherd?? {
        guard let object = try? JSONSerialization.jsonObject(with: message.json) as? [String: Any],
              let response = object["response"] as? [String: Any], response["id"] as? Int == id,
              let result = response["result"] as? [String: Any],
              let sessions = (result["sessions"] as? [String: Any])?["sessions"] as? [[String: Any]],
              let session = sessions.first(where: { $0["id"] as? String == sessionID }) else { return nil }
        guard let raw = session["shepherd"], let data = try? JSONSerialization.data(withJSONObject: raw) else { return .some(nil) }
        return .some(try? JSONDecoder().decode(RemoteShepherd.self, from: data))
    }

    private static func encode(_ body: [String: Any]) -> OpaqueHostMessage {
        OpaqueHostMessage(json: (try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)) ?? Data())
    }
}
