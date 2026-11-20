import Foundation

/// The part of a host's run record the phone can act on without linking AlasHostCore.
public struct RemoteRunRecord: Sendable {
    public enum Status: Equatable, Sendable {
        case starting
        case running
        /// Nil when the host did not observe an exit status, including a stop.
        case finished(exitCode: Int32?)
    }

    public let id: String
    public let name: String
    public let status: Status
    public let visibleConsoleID: String?

    fileprivate init?(_ record: [String: Any]) {
        guard let id = record["id"] as? String, let name = record["scriptName"] as? String,
              let rawStatus = record["status"] as? [String: Any] else { return nil }
        self.id = id
        self.name = name
        visibleConsoleID = record["consoleIsHidden"] as? Bool == false ? record["sessionID"] as? String : nil
        if rawStatus["starting"] != nil {
            status = .starting
        } else if rawStatus["running"] != nil {
            status = .running
        } else if let finished = rawStatus["finished"] as? [String: Any], let outcome = finished["_0"] as? [String: Any] {
            let failure = outcome["failed"] as? [String: Any]
            status = .finished(exitCode: outcome["succeeded"] != nil ? 0 : failure?["exitCode"] as? Int32)
        } else {
            return nil
        }
    }
}

/// The existing host snapshot and event subscription, projected down to runs.
public enum RemoteRunFeed {
    public struct Cursor: Sendable {
        fileprivate let generation: String
        fileprivate let sequence: UInt64
    }

    public enum Update: Sendable {
        case snapshot(id: Int, cursor: Cursor, runs: [RemoteRunRecord])
        case events(changed: [RemoteRunRecord], removed: [String], resync: Bool)
    }

    public static func snapshot(id: Int) -> OpaqueHostMessage {
        RemoteGitRequest.envelope(id: id, ["snapshot": [String: Any]()])
    }

    public static func subscribe(id: Int, after cursor: Cursor) -> OpaqueHostMessage {
        RemoteGitRequest.envelope(id: id, ["subscribe": ["after": ["generation": cursor.generation, "sequence": cursor.sequence]]])
    }

    public static func unsubscribe(id: Int) -> OpaqueHostMessage {
        RemoteGitRequest.envelope(id: id, ["unsubscribe": [String: Any]()])
    }

    public static func update(in message: OpaqueHostMessage) -> Update? {
        guard let object = try? JSONSerialization.jsonObject(with: message.json) as? [String: Any] else { return nil }
        if let response = object["response"] as? [String: Any], let id = response["id"] as? Int,
           let result = response["result"] as? [String: Any], let payload = result["snapshot"] as? [String: Any],
           let snapshot = payload["snapshot"] as? [String: Any], let cursor = snapshot["cursor"] as? [String: Any],
           let generation = cursor["generation"] as? String, let sequence = cursor["sequence"] as? UInt64,
           let runs = snapshot["runs"] as? [[String: Any]] {
            return .snapshot(id: id, cursor: Cursor(generation: generation, sequence: sequence),
                             runs: runs.compactMap(RemoteRunRecord.init))
        }
        guard let payload = object["events"] as? [String: Any], let events = payload["events"] as? [[String: Any]] else { return nil }
        var changed: [RemoteRunRecord] = []
        var removed: [String] = []
        for event in events {
            if event["resync"] != nil { return .events(changed: [], removed: [], resync: true) }
            if let change = event["runChanged"] as? [String: Any], let raw = change["run"] as? [String: Any],
               let record = RemoteRunRecord(raw) { changed.append(record) }
            if let removal = event["runRemoved"] as? [String: Any], let id = removal["id"] as? String { removed.append(id) }
        }
        return .events(changed: changed, removed: removed, resync: false)
    }
}
