import Foundation
import AlasModel
import OSLog

/// Times a `session/load`: its history (the replay's end event) apart from
/// its runtime (the response).
public let acpLoadReplayLogger = Logger(subsystem: "io.nlopez.alas", category: "acp-load")

/// The client-neutral end of a `session/load` history replay (our Claude
/// adapter fork). Alas names an id on the load request
/// (`_meta.loadReplayEnd.id`); after the whole replay, child history included,
/// the adapter sends one `session_info_update` with
/// `_meta.loadReplayEnd: {version, id}`, before the load response. The event
/// says only that the recorded history arrived whole: the load can still fail
/// after it, and it never means the session is ready.
public enum ACPLoadReplayEnd {
    /// `_meta.loadReplayEnd` of a `session/load` request.
    public struct Request: Codable, Equatable, Sendable {
        public let id: String

        public init(id: String) {
            self.id = id
        }
    }

    /// Whether `update` ends the replay of the load that named `loadID`. An end
    /// event of another load, one without an id, or of another version does not.
    public static func ends(_ update: ACPSessionUpdate, loadID: String) -> Bool {
        guard case .sessionInfoUpdate(let info) = update,
              let metadata = info.metadata,
              let data = try? JSONEncoder().encode(metadata) else { return false }
        struct Root: Decodable {
            struct End: Decodable {
                let version: Int?
                let id: String?
            }
            let loadReplayEnd: End?
        }
        guard let end = (try? JSONDecoder().decode(Root.self, from: data))?.loadReplayEnd,
              let version = end.version, version >= 1 else { return false }
        return end.id == loadID
    }

    /// Whole milliseconds since `start`, for the load timing log.
    public static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = (ContinuousClock.now - start).components
        return elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    }
}
