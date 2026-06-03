import Foundation

struct RemoteDevice: Codable, Equatable, Identifiable, Sendable {
    let id: String          // UUID
    var name: String
    var tokenHash: String   // hex SHA-256 of the token; plaintext never stored
    var createdAt: Date
    var lastSeenAt: Date?
}

/// Persistence boundary for paired devices. Production uses a JSON file under
/// Application Support; tests use an in-memory implementation.
protocol RemoteDeviceStore: AnyObject {
    func load() -> [RemoteDevice]
    func save(_ devices: [RemoteDevice])
}

final class InMemoryDeviceStore: RemoteDeviceStore {
    private(set) var saved: [RemoteDevice] = []
    func load() -> [RemoteDevice] { saved }
    func save(_ devices: [RemoteDevice]) { saved = devices }
}
