import AlasCore
import Foundation
import Testing

struct PeerIconTests {
    @Test(arguments: PeerIcon.allCases)
    func roundTripsThroughJSON(_ icon: PeerIcon) throws {
        let data = try JSONEncoder().encode(icon)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(icon.rawValue)\"")
        #expect(try JSONDecoder().decode(PeerIcon.self, from: data) == icon)
    }

    /// A record from a newer build must not fail a whole store.
    @Test func anUnknownIdDecodesAsALaptop() throws {
        #expect(try JSONDecoder().decode(PeerIcon.self, from: Data("\"toaster\"".utf8)) == .laptop)
    }

    @Test(arguments: [nil, "", "toaster"] as [String?])
    func anUnknownWireValueIsNoIcon(_ value: String?) {
        #expect(PeerIcon(wireValue: value) == nil)
    }

    /// An override this build doesn't know falls back to the peer's own icon
    /// rather than failing the whole peer store.
    @Test(arguments: [
        (nil, nil), ("\"macStudio\"", PeerIcon.macStudio), ("\"toaster\"", nil),
    ] as [(String?, PeerIcon?)])
    func aRecordDecodesItsIconOverride(_ override: String?, _ expected: PeerIcon?) throws {
        let extra = override.map { #","iconOverride":\#($0)"# } ?? ""
        let json = #"{"id":"p","serverId":"s","name":"m1max","icon":"server","origins":[],"token":"t","addedAt":0\#(extra)}"#
        let peer = try JSONDecoder().decode(RemotePeer.self, from: Data(json.utf8))
        #expect(peer.name == "m1max")
        #expect(peer.iconOverride == expected)
        #expect(peer.displayIcon == expected ?? .server)
    }
}
