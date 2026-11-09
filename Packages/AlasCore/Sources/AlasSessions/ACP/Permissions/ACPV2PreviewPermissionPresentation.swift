import Foundation
import AlasACP

/// Display values only. An item ID can be acted on only by its live owner.
public struct ACPV2PreviewPermissionItem: Identifiable, Sendable {
    public enum Phase: Equatable, Sendable { case awaitingDecision, sending, unavailable, uncertain }
    public let id: UUID
    public let installationID: UUID
    public let ledgerOrdinal: Int64
    public let permission: ACPV2InteractiveRequest.Permission
    public var phase: Phase

    public init(id: UUID, installationID: UUID, ledgerOrdinal: Int64,
        permission: ACPV2InteractiveRequest.Permission, phase: Phase) {
        self.id = id
        self.installationID = installationID
        self.ledgerOrdinal = ledgerOrdinal
        self.permission = permission
        self.phase = phase
    }
}
