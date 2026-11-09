import Testing
import Foundation
@testable import Alas

struct RemoteDeviceTests {
    @Test func preFederationRecordDecodesAsBrowser() throws {
        let json = Data(#"{"id":"d1","name":"iPhone","tokenHash":"ab","createdAt":"2026-01-02T03:04:05Z"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let device = try decoder.decode(RemoteDevice.self, from: json)
        #expect(device.kind == .browser)
        #expect(device.peerServerId == nil)
        #expect(device.lastSeenAt == nil)
        #expect(device.scope == .full)
    }

    /// A scope this build does not know comes from a newer one, which only
    /// ever narrows a token, so it is read as the narrowest.
    @Test func anUnknownScopeDecodesAsTheNarrowest() throws {
        let json = Data(#"{"id":"d1","name":"Host","tokenHash":"ab","createdAt":"2026-01-02T03:04:05Z","scope":"readOnly"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(RemoteDevice.self, from: json).scope == .delegation)
    }

    @Test func peerRecordRoundTrips() throws {
        let device = RemoteDevice(id: "d2", name: "Studio", tokenHash: "cd", createdAt: Date(timeIntervalSince1970: 1),
                                  lastSeenAt: nil, kind: .alasInstance, peerServerId: "srv-b")
        let data = try JSONEncoder().encode(device)
        let back = try JSONDecoder().decode(RemoteDevice.self, from: data)
        #expect(back == device)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "alasInstance")
        #expect(object["peerServerId"] as? String == "srv-b")
    }
}
