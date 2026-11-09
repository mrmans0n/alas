import Foundation

/// A view-only copy of projected rows. It contains no journal or reply authority.
public struct ACPV2PreviewDisplaySnapshot: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case observing, interrupted, ended, failed }
    public struct Row: Codable, Equatable, Sendable {
        public let identity: ACPMessage.StableIdentityKey
        public let kind: String
        public let payload: Data

        public init(identity: ACPMessage.StableIdentityKey, kind: String, payload: Data) {
            self.identity = identity
            self.kind = kind
            self.payload = payload
        }
    }
    public let formatVersion: Int
    public let sessionId: String
    public let installationID: UUID
    public let sequence: Int64
    public let status: Status
    public let rows: [Row]
    public let failureMessage: String?
    public var reopenedStatus: Status { status == .observing ? .interrupted : status }

    public init(sessionId: String, installationID: UUID, sequence: Int64, status: Status, rows: [Row], formatVersion: Int = 1, failureMessage: String? = nil) {
        self.formatVersion = formatVersion
        self.sessionId = sessionId
        self.installationID = installationID
        self.sequence = sequence
        self.status = status
        self.rows = rows
        self.failureMessage = failureMessage
    }

    @MainActor
    public init(sessionId: String, installationID: UUID, sequence: Int64, status: Status, messages: [ACPMessage], failureMessage: String? = nil) throws {
        self.init(sessionId: sessionId, installationID: installationID, sequence: sequence, status: status,
            rows: try messages.map { .init(identity: $0.stableIdentityKey, kind: $0.kind, payload: try ACPMessageCodec.encode($0)) }, failureMessage: failureMessage)
        try validate()
    }

    func validate() throws {
        guard formatVersion == 1, !sessionId.isEmpty, sequence > 0,
              Set(rows.map(\.identity)).count == rows.count else { throw ACPV2PreviewStoreError.invalidInput }
    }

    @MainActor
    public func decodeMessages() throws -> [ACPMessage] {
        try validate()
        return try rows.map { try ACPMessageCodec.decode(kind: $0.kind, payload: $0.payload, identity: $0.identity) }
    }
}
