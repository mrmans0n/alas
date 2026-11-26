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
}
