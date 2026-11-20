import AlasCore
import Foundation
import Testing

@MainActor
struct PeerDeviceGrantsTests {
    @Test func sameNameDevicesAndDifferentPairingsHaveIndependentGrants() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let grants = try PeerDeviceGrants(file: file)
        let first = try grants.setAccess(.control, serial: "serial-A", name: "Android", pairingID: "phone-A")
        let second = try grants.setAccess(.view, serial: "serial-B", name: "Android", pairingID: "phone-B")
        #expect(first != second)

        let restored = try PeerDeviceGrants(file: file)
        #expect(restored.sharedIDs(for: "phone-A") == [first])
        #expect(restored.sharedIDs(for: "phone-B") == [second])
        #expect(restored.sharedIDs(for: "new-pairing").isEmpty)
        #expect(restored.access(to: first, pairingID: "phone-A") == .control)
        #expect(restored.access(to: first, pairingID: "phone-B") == nil)
        #expect(restored.access(serial: "serial-B", pairingID: "phone-A") == nil)
        #expect(restored.serial(for: first) == "serial-A")
        #expect(restored.name(for: first) == "Android")
    }

    @Test func downgradeAndIndividualRevocationPersistWithoutChangingDeviceID() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let grants = try PeerDeviceGrants(file: file)
        let id = try grants.setAccess(.control, serial: "serial-A", name: "Android", pairingID: "phone-A")
        _ = try grants.setAccess(.view, serial: "serial-A", name: "Android", pairingID: "phone-B")

        let reopened = try PeerDeviceGrants(file: file)
        let downgraded = try reopened.setAccess(.view, serial: "serial-A", name: "Renamed", pairingID: "phone-A")
        #expect(downgraded == id)
        let afterDowngrade = try PeerDeviceGrants(file: file)
        #expect(afterDowngrade.access(to: id, pairingID: "phone-A") == .view)
        #expect(afterDowngrade.name(for: id) == "Renamed")
        _ = try afterDowngrade.setAccess(nil, serial: "serial-A", name: "Renamed", pairingID: "phone-A")

        let restored = try PeerDeviceGrants(file: file)
        #expect(restored.sharedIDs(for: "phone-A").isEmpty)
        #expect(restored.access(to: id, pairingID: "phone-B") == .view)
    }

    @Test func forgettingPairingAndStoppingSharingClearOnlyTheirGrants() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let grants = try PeerDeviceGrants(file: file)
        let first = try grants.setAccess(.view, serial: "serial-A", name: "Android", pairingID: "forgotten")
        let second = try grants.setAccess(.control, serial: "serial-B", name: "Android", pairingID: "forgotten")
        _ = try grants.setAccess(.control, serial: "serial-A", name: "Android", pairingID: "remaining")
        _ = try grants.setAccess(.view, serial: "serial-B", name: "Android", pairingID: "remaining")
        _ = try grants.setAccess(.view, serial: "serial-A", name: "Android", pairingID: "another")
        try grants.removePairing("forgotten")
        let afterForget = try PeerDeviceGrants(file: file)
        #expect(afterForget.sharedIDs(for: "forgotten").isEmpty)
        #expect(afterForget.access(to: first, pairingID: "remaining") == .control)

        try afterForget.stopSharing(serial: "serial-A")
        let restored = try PeerDeviceGrants(file: file)
        #expect(restored.sharedIDs(for: "remaining") == [second])
        #expect(restored.sharedIDs(for: "another").isEmpty)
    }

    @Test func failedWriteLeavesExistingAccessUnchanged() throws {
        let file = temporaryFile()
        let directory = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grants = try PeerDeviceGrants(file: file)
        let id = try grants.setAccess(.view, serial: "serial-A", name: "Android", pairingID: "phone-A")
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)

        #expect(throws: (any Error).self) {
            try grants.setAccess(.control, serial: "serial-A", name: "Changed", pairingID: "phone-A")
        }
        #expect(grants.access(to: id, pairingID: "phone-A") == .view)
        #expect(grants.name(for: id) == "Android")
    }

    @Test func corruptGrantFileIsRejectedAndPreserved() throws {
        let file = temporaryFile()
        let directory = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: file)

        #expect(throws: DecodingError.self) { try PeerDeviceGrants(file: file) }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("grants.json")
    }
}
