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

    /// Apple silicon reports a generic `hw.model`, so the product name decides;
    /// older Macs only have the model identifier.
    @Test(arguments: [
        ("Mac mini (2024)", "Mac16,10", PeerIcon.macMini),
        ("Mac Studio (2025)", "Mac16,9", .macStudio),
        ("Mac Pro (2023)", "Mac14,8", .macPro),
        ("MacBook Pro (16-inch, 2021)", "MacBookPro18,2", .laptop),
        ("iMac (24-inch, 2024)", "Mac16,2", .desktop),
        (nil, "Macmini9,1", .macMini),
        (nil, "MacPro7,1", .macPro),
        (nil, "iMac20,1", .desktop),
        (nil, "MacBookAir10,1", .laptop),
    ] as [(String?, String?, PeerIcon)])
    func picksTheIconForTheHardware(_ productName: String?, _ model: String?, _ expected: PeerIcon) {
        #expect(PeerIcon(productName: productName, model: model) == expected)
    }

    @Test(arguments: [(nil, nil), (nil, "Mac16,10"), ("Apple Virtual Machine 1", "VirtualMac2,1")] as [(String?, String?)])
    func anUnrecognisedMachineHasNoHardwareIcon(_ productName: String?, _ model: String?) {
        #expect(PeerIcon(productName: productName, model: model) == nil)
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

    @Test(arguments: [
        ("wss://m1max.tail1234.ts.net", PeerConnectionKind.tailscale),
        ("ws://100.101.2.3:7420", .tailscale),
        ("ws://100.63.0.1:7420", .host("100.63.0.1")),
        ("ws://m1max.local:7420", .lan),
        ("ws://192.168.1.4:7420", .lan),
        ("ws://10.0.0.2", .lan),
        ("ws://172.20.1.1", .lan),
        ("ws://172.32.1.1", .host("172.32.1.1")),
        ("ws://[fd00::1]:7420", .lan),
        ("ws://[fe80::1]:7420", .lan),
        ("wss://mac.example.com", .host("mac.example.com")),
    ] as [(String, PeerConnectionKind)])
    func anOriginNamesHowThePeerIsReached(_ origin: String, _ expected: PeerConnectionKind) {
        #expect(PeerConnectionKind.of(origin: origin) == expected)
    }

    @Test(arguments: [nil, "", "not a url"] as [String?])
    func noOriginIsNoConnectionKind(_ origin: String?) {
        #expect(PeerConnectionKind.of(origin: origin) == nil)
    }
}
