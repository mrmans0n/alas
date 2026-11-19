import AlasFoundation
import AlasModel
import Foundation

/// Host-only device identities and pairing grants. An edit is visible only after it is saved.
@MainActor
public final class PeerDeviceGrants {
    private struct Device: Codable, Equatable {
        let id: PeerDeviceID
        let serial: String
        var name: String
        var access: [String: PeerDeviceAccess] = [:]
    }

    public static var defaultURL: URL {
        Paths.remoteDevicesFile.deletingLastPathComponent().appendingPathComponent("peer-device-grants.json")
    }

    private let file: URL
    private let store = PersistenceStore()
    private var devices: [PeerDeviceID: Device] = [:]

    public init(file: URL) throws {
        self.file = file
        let loaded: [Device]
        do {
            // Unlike the general recovery path, leave a corrupt authorization file in place.
            loaded = try store.read([Device].self, from: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
        var serials: Set<String> = []
        for device in loaded {
            guard devices[device.id] == nil, serials.insert(device.serial).inserted else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Duplicate peer device identity"))
            }
            devices[device.id] = device
        }
    }

    @discardableResult
    public func setAccess(_ access: PeerDeviceAccess?, serial: String, name: String, pairingID: String) throws -> PeerDeviceID {
        var device = device(forSerial: serial) ?? Device(id: UUID(), serial: serial, name: name)
        device.name = name
        device.access[pairingID] = access
        var updated = devices
        updated[device.id] = device
        try save(updated)
        return device.id
    }

    public func stopSharing(serial: String) throws {
        guard var device = device(forSerial: serial), !device.access.isEmpty else { return }
        device.access.removeAll()
        var updated = devices
        updated[device.id] = device
        try save(updated)
    }

    public func removePairing(_ pairingID: String) throws {
        var updated = devices
        for device in devices.values where device.access[pairingID] != nil {
            updated[device.id]?.access.removeValue(forKey: pairingID)
        }
        try save(updated)
    }

    public func sharedIDs(for pairingID: String) -> [PeerDeviceID] {
        devices.values.compactMap { $0.access[pairingID] == nil ? nil : $0.id }.sorted()
    }

    public func access(to id: PeerDeviceID, pairingID: String) -> PeerDeviceAccess? {
        devices[id]?.access[pairingID]
    }

    public func serial(for id: PeerDeviceID) -> String? { devices[id]?.serial }
    public func name(for id: PeerDeviceID) -> String? { devices[id]?.name }

    public func access(serial: String, pairingID: String) -> PeerDeviceAccess? {
        device(forSerial: serial)?.access[pairingID]
    }

    private func device(forSerial serial: String) -> Device? {
        devices.values.first { $0.serial == serial }
    }

    private func save(_ updated: [PeerDeviceID: Device]) throws {
        guard updated != devices else { return }
        try store.write(updated.values.sorted { $0.id < $1.id }, to: file)
        devices = updated
    }
}
