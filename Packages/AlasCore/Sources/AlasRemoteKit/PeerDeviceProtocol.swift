import Foundation

public enum PeerDeviceCapability: Sendable {
    /// Advertised in `hello` by hosts that serve direct peer device attachments.
    public static let v1 = "peer.device.v1"
}

/// Opaque network identifier. The host's Android serial never goes on the wire.
public typealias PeerDeviceID = UUID

public enum PeerDeviceAccess: String, Codable, Equatable, Sendable {
    case view, control
}

public enum PeerDeviceAvailability: String, Codable, Equatable, Sendable {
    case ready, absent, unauthorized, offline, interrupted
}

public enum PeerDeviceDriver: Codable, Equatable, Sendable {
    case available
    case agent(name: String)
    case local
    case you
    case other(name: String)
}

public struct PeerDeviceSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: PeerDeviceID
    public let name: String
    public let access: PeerDeviceAccess
    public let availability: PeerDeviceAvailability
    public let driver: PeerDeviceDriver

    public init(id: PeerDeviceID, name: String, access: PeerDeviceAccess,
                availability: PeerDeviceAvailability, driver: PeerDeviceDriver) {
        self.id = id
        self.name = name
        self.access = access
        self.availability = availability
        self.driver = driver
    }
}

public enum PeerDeviceButton: String, Codable, Equatable, Sendable {
    case back, home, recents, power
}

public enum PeerDevicePointerPhase: String, Codable, Equatable, Sendable {
    case begin, move, end, cancel
}

public enum PeerDeviceInput: Codable, Equatable, Sendable {
    case pointer(phase: PeerDevicePointerPhase, x: Double, y: Double)
    case key(usage: UInt32, down: Bool)
    case text(String)
    case scroll(x: Double, y: Double, dx: Double, dy: Double)
    case button(PeerDeviceButton)
}

/// Device requests belong to a direct paired link, not a federated session.
public enum PeerDeviceRequest: Codable, Equatable, Sendable {
    case list
    case attach(deviceID: PeerDeviceID, attachmentID: UUID)
    case detach(attachmentID: UUID)
    case takeControl(attachmentID: UUID)
    case releaseControl(attachmentID: UUID)
    case renewControl(attachmentID: UUID, generation: UInt64)
    case input(attachmentID: UUID, leaseGeneration: UInt64, formatGeneration: UInt64, event: PeerDeviceInput)
}

public enum PeerDeviceEvent: Codable, Equatable, Sendable {
    case list([PeerDeviceSummary])
    /// Redeem the ticket at the fixed media route on the verified control origin.
    case attached(attachmentID: UUID, ticket: String)
    case control(attachmentID: UUID, driver: PeerDeviceDriver, generation: UInt64)
    case refused(attachmentID: UUID, reason: String)
    case detached(attachmentID: UUID, reason: String)
}
