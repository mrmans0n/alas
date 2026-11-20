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
    /// The request's header, checks and threads, or a stack's entries; nil from hosts before it was sent.
    public var detail: Detail?

    public init(badge: String, number: String? = nil, tooltip: String = "", resumable: Bool? = nil,
                phaseLine: String? = nil, autoFix: Bool? = nil, autoMerge: Bool? = nil, detail: Detail? = nil) {
        self.badge = badge
        self.number = number
        self.tooltip = tooltip
        self.resumable = resumable
        self.phaseLine = phaseLine
        self.autoFix = autoFix
        self.autoMerge = autoMerge
        self.detail = detail
    }

    /// `HostSessionShepherd.Detail`.
    public struct Detail: Decodable, Equatable, Sendable {
        public var title: String?
        public var url: URL?
        /// "feature → main" for a request; the stack name for a stack.
        public var branch: String?
        public var headSHA: String?
        public var provider: String
        public var requestLabel: String
        /// Nil until the Mac has seen this request; empty when it has no checks.
        public var checks: [Check]?
        public var openThreads: Int?
        public var trustedThreads: Int?
        public var fixAttempts: Int
        public var fixAttemptBudget: Int
        /// Stacks only, highest position first.
        public var stackEntries: [StackEntry]?

        public init(title: String? = nil, url: URL? = nil, branch: String? = nil, headSHA: String? = nil,
                    provider: String, requestLabel: String, checks: [Check]? = nil, openThreads: Int? = nil,
                    trustedThreads: Int? = nil, fixAttempts: Int = 0, fixAttemptBudget: Int = 0,
                    stackEntries: [StackEntry]? = nil) {
            self.title = title
            self.url = url
            self.branch = branch
            self.headSHA = headSHA
            self.provider = provider
            self.requestLabel = requestLabel
            self.checks = checks
            self.openThreads = openThreads
            self.trustedThreads = trustedThreads
            self.fixAttempts = fixAttempts
            self.fixAttemptBudget = fixAttemptBudget
            self.stackEntries = stackEntries
        }
    }

    public struct Check: Decodable, Equatable, Sendable {
        public var name: String
        /// A `ReviewCheckBucket` raw value.
        public var bucket: String
        public var url: URL?

        public init(name: String, bucket: String, url: URL? = nil) {
            self.name = name
            self.bucket = bucket
            self.url = url
        }
    }

    public struct StackEntry: Decodable, Equatable, Sendable {
        public var position: Int
        public var number: String
        public var title: String
        /// A `ShepherdBadgeState` raw value.
        public var badge: String
        public var phaseLine: String
        public var url: URL?

        public init(position: Int, number: String, title: String, badge: String, phaseLine: String, url: URL? = nil) {
            self.position = position
            self.number = number
            self.title = title
            self.badge = badge
            self.phaseLine = phaseLine
            self.url = url
        }
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

/// What the host's session list says about Ship for one session.
public struct RemoteShepherdListing: Equatable, Sendable {
    public var shepherd: RemoteShepherd?
    /// Ship would publish a stack for this session.
    public var shipsStack: Bool

    public init(shepherd: RemoteShepherd?, shipsStack: Bool) {
        self.shepherd = shepherd
        self.shipsStack = shipsStack
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

    /// Session `sessionID`'s entry in the session list answering `id`: a listing without a shepherd when
    /// the host lists it without one, nil when `message` answers something else or doesn't list the session.
    /// A `shepherd` this phone can't read counts as none.
    public static func listing(of sessionID: String, replying id: Int, in message: OpaqueHostMessage) -> RemoteShepherdListing? {
        guard let object = try? JSONSerialization.jsonObject(with: message.json) as? [String: Any],
              let response = object["response"] as? [String: Any], response["id"] as? Int == id,
              let result = response["result"] as? [String: Any],
              let sessions = (result["sessions"] as? [String: Any])?["sessions"] as? [[String: Any]],
              let session = sessions.first(where: { $0["id"] as? String == sessionID }) else { return nil }
        let shepherd = session["shepherd"]
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode(RemoteShepherd.self, from: $0) }
        return RemoteShepherdListing(shepherd: shepherd, shipsStack: session["shipsStack"] as? Bool == true)
    }

    private static func encode(_ body: [String: Any]) -> OpaqueHostMessage {
        OpaqueHostMessage(json: (try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)) ?? Data())
    }
}
