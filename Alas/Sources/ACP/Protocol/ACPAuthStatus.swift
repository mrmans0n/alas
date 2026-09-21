import Foundation

/// Proactive auth status pushed by the shared `_auth/status_update` ACP
/// extension (claude-agent-acp >= 0.75, codex-acp >= 1.9). Agents advertise
/// support via `agentCapabilities._meta.authStatus` on `initialize`, then
/// send this once right after the initialize response and again whenever
/// the status changes (authenticate, logout, session create/fork/load,
/// account update).
struct ACPAuthStatus: Codable, Equatable {
    let kind: Kind
    let label: String
    let detail: String?
    let account: Account?
    /// Opaque vendor-specific payload. Preserved but not interpreted.
    let vendor: AnyCodable?

    enum Kind: Equatable {
        case account
        case apiKey
        case gateway
        case external
        case none
        case unknown(String)
    }

    struct Account: Codable, Equatable {
        let email: String?
        let organization: String?
        let plan: String?
    }

    init(
        kind: Kind,
        label: String,
        detail: String? = nil,
        account: Account? = nil,
        vendor: AnyCodable? = nil
    ) {
        self.kind = kind
        self.label = label
        self.detail = detail
        self.account = account
        self.vendor = vendor
    }

    private enum CodingKeys: String, CodingKey {
        case kind, label, detail, account, vendor
    }

    // Defensive decoding matches the rest of the ACP protocol layer: a
    // missing `label` (an agent forward-compatibility slip) shouldn't fail
    // the whole notification and leave the UI with no status at all.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        account = try c.decodeIfPresent(Account.self, forKey: .account)
        vendor = try? c.decodeIfPresent(AnyCodable.self, forKey: .vendor)
    }
}

extension ACPAuthStatus.Kind: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "account": self = .account
        case "api_key": self = .apiKey
        case "gateway": self = .gateway
        case "external": self = .external
        case "none": self = .none
        case let value: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .account: try c.encode("account")
        case .apiKey: try c.encode("api_key")
        case .gateway: try c.encode("gateway")
        case .external: try c.encode("external")
        case .none: try c.encode("none")
        case .unknown(let value): try c.encode(value)
        }
    }
}

/// Wire params for the `_auth/status_update` notification.
struct ACPAuthStatusUpdateParams: Codable, Equatable {
    let authStatus: ACPAuthStatus
}

/// A single `_auth/status_update` delivery, paired with an optional durable
/// acknowledgement. On a broker connection, the broker replays this
/// notification (and holds its acknowledged-cursor back) until the
/// consumer calls this closure — normally once the status has actually
/// been persisted, so a crash between delivery and persistence doesn't
/// silently drop the notification for the next process's replay.
struct ACPAuthStatusEvent {
    let status: ACPAuthStatus
    let durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement?

    init(status: ACPAuthStatus, durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement? = nil) {
        self.status = status
        self.durableConsumptionAcknowledgement = durableConsumptionAcknowledgement
    }
}
