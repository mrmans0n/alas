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
}
