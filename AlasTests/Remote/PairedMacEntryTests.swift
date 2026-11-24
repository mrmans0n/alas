import Foundation
import Testing
@testable import Alas

struct PairedMacEntryTests {
    private func peer(_ serverId: String, deviceId: String? = nil, token: String = "t") -> RemotePeer {
        RemotePeer(id: "peer-\(serverId)", serverId: serverId, name: serverId, origins: ["http://\(serverId):8765"],
                   token: token, publicKey: token.isEmpty ? nil : "key", localDeviceId: deviceId, addedAt: .distantPast)
    }

    private func device(_ id: String, serverId: String?, kind: RemoteDeviceKind = .alasInstance, at seconds: Double = 0) -> RemoteDevice {
        RemoteDevice(id: id, name: "device \(id)", tokenHash: "h", createdAt: Date(timeIntervalSince1970: seconds),
                     lastSeenAt: nil, kind: kind, peerServerId: serverId)
    }

    @Test func eachMacIsOneEntryWithItsDevicesWhicheverWayItIsLinked() {
        let entries = PairedMacEntry.entries(
            peers: [peer("studio", deviceId: "d1"), peer("air")],
            devices: [
                device("d1", serverId: nil),
                // A re-pair left a second device carrying the same identity.
                device("d2", serverId: "studio", at: 1),
                device("d3", serverId: "air"),
                device("phone", serverId: nil, kind: .phone),
            ]
        )

        #expect(entries.map(\.id) == ["studio", "air"])
        #expect(entries[0].devices.map(\.id) == ["d1", "d2"])
        #expect(entries[1].devices.map(\.id) == ["d3"])
        #expect(entries.map(\.isPairedBothWays) == [true, true])
    }

    @Test func aMacKnownOnlyByItsDevicesFollowsThePeersGroupedByIdentity() {
        let entries = PairedMacEntry.entries(
            peers: [peer("studio")],
            devices: [device("h2", serverId: "host", at: 2), device("h1", serverId: "host", at: 1), device("loose", serverId: nil, at: 3)]
        )

        #expect(entries.map(\.id) == ["studio", "host", "loose"])
        #expect(entries[1].devices.map(\.id) == ["h1", "h2"])
        #expect(entries[1].peer == nil)
        #expect(!entries[1].isPairedBothWays)
        // This Mac dials studio, but studio has no device here.
        #expect(!entries[0].isPairedBothWays)
    }
}
