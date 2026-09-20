import Testing
@testable import Alas

struct RemotePairingLinkTests {
    private func address(_ kind: RemoteAdvertisedAddress.Kind, _ host: String) -> RemoteAdvertisedAddress {
        RemoteAdvertisedAddress(kind: kind, interfaceName: nil, host: host, port: 8765, isRecommended: false)
    }

    @Test func linkKeepsTheBaseFirstAndListsEveryAddress() {
        let link = RemotePairingLink.build(
            base: "http://100.64.1.5:8765",
            code: "ABC123",
            addresses: [address(.lan, "192.168.1.20"), address(.tailnet, "100.64.1.5")]
        )
        #expect(link == "http://100.64.1.5:8765/?code=ABC123&hosts=http%3A%2F%2F100.64.1.5%3A8765,http%3A%2F%2F192.168.1.20%3A8765")
    }

    @Test func linkWithoutAddressesStillCarriesTheBase() {
        let link = RemotePairingLink.build(base: "http://localhost:8765", code: "X", addresses: [])
        #expect(link == "http://localhost:8765/?code=X&hosts=http%3A%2F%2Flocalhost%3A8765")
    }

    @Test func ipv6OriginsAreBracketedAndEncoded() {
        let link = RemotePairingLink.build(base: "http://[fd7a::1]:8765", code: "X", addresses: [])
        #expect(link.hasSuffix("&hosts=http%3A%2F%2F%5Bfd7a%3A%3A1%5D%3A8765"))
    }

    @Test func parseRecoversOriginsInOrderWithBaseFirst() throws {
        let addresses = [
            RemoteAdvertisedAddress(kind: .tailnet, interfaceName: "utun3", host: "100.64.1.5", port: 8765, isRecommended: true),
            RemoteAdvertisedAddress(kind: .lan, interfaceName: "en0", host: "192.168.1.20", port: 8765, isRecommended: false),
        ]
        let link = RemotePairingLink.build(base: "http://100.64.1.5:8765", code: "ABC123", addresses: addresses)
        let parts = try #require(RemotePairingLink.parse(link))
        #expect(parts.code == "ABC123")
        #expect(parts.origins == ["http://100.64.1.5:8765", "http://192.168.1.20:8765"])
    }

    @Test func parseLegacyLinkWithoutHostsUsesItsOwnOrigin() throws {
        let parts = try #require(RemotePairingLink.parse("http://192.168.1.20:8765/?code=ABC123"))
        #expect(parts.origins == ["http://192.168.1.20:8765"])
    }

    @Test func parseRejectsNonLinksAndMissingCode() {
        #expect(RemotePairingLink.parse("") == nil)
        #expect(RemotePairingLink.parse("not a link") == nil)
        #expect(RemotePairingLink.parse("http://192.168.1.20:8765/") == nil)
        #expect(RemotePairingLink.parse("ftp://192.168.1.20:8765/?code=A") == nil)
    }

    @Test func normalizeOriginBracketsIPv6AndKeepsPort() {
        #expect(RemotePairingLink.normalizeOrigin("http://[fd7a:115c:a1e0::1]:8765/anything") == "http://[fd7a:115c:a1e0::1]:8765")
        #expect(RemotePairingLink.normalizeOrigin("http://nacho.local:8765") == "http://nacho.local:8765")
        #expect(RemotePairingLink.normalizeOrigin("mailto:x") == nil)
    }
}
