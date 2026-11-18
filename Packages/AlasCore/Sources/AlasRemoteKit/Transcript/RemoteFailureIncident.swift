import Foundation

public enum ACPFailureSeverity: String, Codable, Sendable {
    case warning, error

    public var label: String {
        switch self {
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}

public enum ACPFailureCategory: String, Sendable {
    case connection, access, limit, request, service, unknown

    public var label: String {
        switch self {
        case .connection: "Connection"
        case .access: "Access"
        case .limit: "Limit"
        case .request: "Request"
        case .service: "Service"
        case .unknown: "Other"
        }
    }
}

/// An `ACPFailureIncident` as a peer reads it from `RemoteWireMessage.json`:
/// what its card shows. The host strips the actions, which peers cannot run.
/// Like the Mac's record, it needs an id and a title, and any other field
/// that does not decode takes its default.
public struct RemoteFailureIncident: Decodable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let details: String?
    /// The raw category, kept so a newer one survives; read `knownCategory`.
    public let category: String
    public let severity: ACPFailureSeverity
    public let kind: String?
    public let endedTurn: Bool

    public var knownCategory: ACPFailureCategory { ACPFailureCategory(rawValue: category) ?? .unknown }

    private enum CodingKeys: String, CodingKey {
        case record, endedTurn, id, title, details, category, severity, kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let r = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .record)
        id = try r.decode(String.self, forKey: .id)
        title = try r.decode(String.self, forKey: .title)
        details = try? r.decodeIfPresent(String.self, forKey: .details)
        category = (try? r.decodeIfPresent(String.self, forKey: .category)) ?? ACPFailureCategory.unknown.rawValue
        severity = (try? r.decodeIfPresent(ACPFailureSeverity.self, forKey: .severity)) ?? .error
        kind = try? r.decodeIfPresent(String.self, forKey: .kind)
        endedTurn = (try? c.decodeIfPresent(Bool.self, forKey: .endedTurn)) ?? false
    }
}
