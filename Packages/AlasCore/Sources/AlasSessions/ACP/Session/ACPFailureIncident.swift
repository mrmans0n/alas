import Foundation
import AlasACP

/// A structured failure the agent reported, kept as one transcript row per
/// record id. It is never agent output: not progress, not last-agent text,
/// and it does not close a run of output.
public struct ACPFailureIncident: Codable, Equatable, Sendable {
    public var record: ACPSessionFailureRecord
    /// Set once a prompt response carried it as an error ending the turn. Never set by
    /// `session_info_update` or replay, so a background error is not a turn failure.
    public var endedTurn: Bool

    public init(record: ACPSessionFailureRecord, endedTurn: Bool = false) {
        self.record = record
        self.endedTurn = endedTurn
    }

    /// The title, then a blank line and the details when present.
    public var displayText: String {
        record.details.map { "\(record.title)\n\n\($0)" } ?? record.title
    }
}

/// The persisted payload of a `"system"` row, shared by `ACPMessageCodec` and
/// `ACPMessageWire`. An incident keeps its title in `text`, so an older build
/// sharing the store shows it as a notice. An incident that does not decode,
/// bad or from a future version, leaves the row a notice here too.
struct ACPSystemRowPayload: Codable {
    let text: String
    let failureIncident: ACPFailureIncident?

    init(text: String) {
        self.text = text
        failureIncident = nil
    }

    init(failureIncident: ACPFailureIncident) {
        text = failureIncident.record.title
        self.failureIncident = failureIncident
    }

    private enum CodingKeys: String, CodingKey {
        case text, failureIncident
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        failureIncident = try? c.decodeIfPresent(ACPFailureIncident.self, forKey: .failureIncident)
    }
}
