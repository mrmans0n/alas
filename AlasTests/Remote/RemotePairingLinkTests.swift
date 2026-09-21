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

    // A pasted link's `hosts` can carry an arbitrary number of entries.
    // `RemotePeerPairer` dials every parsed origin sequentially with a
    // multi-second timeout each, so an unbounded list — malformed or
    // hostile — could stall an Add attempt for minutes; the cap is applied
    // before any of them are ever dialed.
    @Test func parseCapsTheNumberOfOriginsAccepted() throws {
        let hosts = (1...20).map { RemotePairingLink.encodeOrigin("http://10.0.0.\($0):8765") }.joined(separator: ",")
        let link = "http://10.0.0.1:8765/?code=ABC123&hosts=\(hosts)"
        let parts = try #require(RemotePairingLink.parse(link))
        #expect(parts.origins.count == RemotePairingLink.maxOrigins)
        #expect(parts.origins == (1...RemotePairingLink.maxOrigins).map { "http://10.0.0.\($0):8765" })
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

    @Test func parseDoesNotManufactureAnOriginFromAnEncodedComma() throws {
        // One `hosts` entry whose text contains a comma arrives as %2C.
        // Decoding before splitting would yield a second, never-advertised origin.
        let link = "http://10.0.0.1:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.1%3A8765%2Chttp%3A%2F%2Fevil.example%3A9999"
        let parts = try #require(RemotePairingLink.parse(link))
        #expect(!parts.origins.contains("http://evil.example:9999"))
        // The single "hosts" entry decodes to a comma-bearing string that fails
        // to parse as one origin, so it is dropped entirely; only the link's
        // own origin fallback survives.
        #expect(parts.origins == ["http://10.0.0.1:8765"])
    }
}
