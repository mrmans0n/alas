import Testing
@testable import Alas

struct RemoteFederatedSessionIDTests {
    @Test func composeJoinsWithAColon() {
        #expect(RemoteFederatedSessionID.compose(serverId: "srv-b", sessionId: "abc") == "srv-b:abc")
    }

    @Test func parseSplitsOnTheFirstColonOnlyForAKnownPeer() throws {
        let parsed = try #require(RemoteFederatedSessionID.parse("srv-b:abc:def", peers: ["srv-b"]))
        #expect(parsed.serverId == "srv-b")
        #expect(parsed.sessionId == "abc:def")
    }

    @Test func parseTreatsUnknownPrefixesAsLocal() {
        #expect(RemoteFederatedSessionID.parse("srv-c:abc", peers: ["srv-b"]) == nil)
        #expect(RemoteFederatedSessionID.parse("abc", peers: ["srv-b"]) == nil)
        #expect(RemoteFederatedSessionID.parse("srv-b:", peers: ["srv-b"]) == nil)
        #expect(RemoteFederatedSessionID.parse(":abc", peers: [""]) == nil)
    }

    @Test func composeThenParseRoundTrips() throws {
        let id = RemoteFederatedSessionID.compose(serverId: "0B1D", sessionId: "sess")
        let parsed = try #require(RemoteFederatedSessionID.parse(id, peers: ["0B1D"]))
        #expect(parsed.sessionId == "sess")
    }
}
