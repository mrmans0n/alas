import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Proactive auth status pushed by the shared `_auth/status_update` ACP
/// extension (claude-agent-acp >= 0.75, codex-acp >= 1.9). Agents advertise
/// support via `agentCapabilities._meta.authStatus` on `initialize`, then
/// send this once right after the initialize response and again whenever
/// the status changes (authenticate, logout, session create/fork/load,
/// account update).
public struct ACPAuthStatus: Codable, Equatable, Sendable {
    public let kind: Kind
    public let label: String
    public let detail: String?
    public let account: Account?
    /// Opaque vendor-specific payload. Preserved but not interpreted.
    public let vendor: AnyCodable?

    public enum Kind: Equatable, Sendable {
        case account
        case apiKey
        case gateway
        case external
        case none
        case unknown(String)
    }

    public struct Account: Codable, Equatable, Sendable {
        public let email: String?
        public let organization: String?
        public let plan: String?

        public init(email: String?, organization: String?, plan: String?) {
            self.email = email
            self.organization = organization
            self.plan = plan
        }
    }

    public init(
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
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        account = try c.decodeIfPresent(Account.self, forKey: .account)
        vendor = try? c.decodeIfPresent(AnyCodable.self, forKey: .vendor)
    }
}

extension ACPAuthStatus.Kind: Codable {
    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
public struct ACPAuthStatusUpdateParams: Codable, Equatable, Sendable {
    public let authStatus: ACPAuthStatus

    public init(authStatus: ACPAuthStatus) {
        self.authStatus = authStatus
    }
}

/// A single `_auth/status_update` delivery, paired with an optional durable
/// acknowledgement. On a broker connection, the broker replays this
/// notification (and holds its acknowledged-cursor back) until the
/// consumer calls this closure — normally once the status has actually
/// been persisted, so a crash between delivery and persistence doesn't
/// silently drop the notification for the next process's replay.
public struct ACPAuthStatusEvent: Sendable {
    public let status: ACPAuthStatus
    public let durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement?

    public init(status: ACPAuthStatus, durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement? = nil) {
        self.status = status
        self.durableConsumptionAcknowledgement = durableConsumptionAcknowledgement
    }
}
