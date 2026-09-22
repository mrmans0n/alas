import Testing
import Foundation
import Network
@testable import Alas

struct RemoteBonjourServiceTests {
    @Test func txtRoundTripsIdentityVersionAndModel() {
        let txt = RemoteBonjourTXT(serverId: "srv-a", protocolVersion: 7, model: "Mac16,6")
        #expect(RemoteBonjourTXT(txt: txt.nwTXTRecord) == txt)
    }

    @Test func txtWithoutModelRoundTripsAsNil() {
        let txt = RemoteBonjourTXT(serverId: "srv-a", model: nil)
        let back = RemoteBonjourTXT(txt: txt.nwTXTRecord)
        #expect(back?.model == nil)
        #expect(back?.protocolVersion == RemoteProtocolVersion.current)
    }

    @Test func txtWithoutAnIdIsNotAnAlasRecord() {
        var record = NWTXTRecord()
        record["v"] = "1"
        record["model"] = "Mac16,6"
        #expect(RemoteBonjourTXT(txt: record) == nil)
        record["id"] = "   "
        #expect(RemoteBonjourTXT(txt: record) == nil)
    }

    @Test func txtWithANonIntegerVersionIsRejected() {
        var record = NWTXTRecord()
        record["id"] = "srv-a"
        record["v"] = "one"
        #expect(RemoteBonjourTXT(txt: record) == nil)
        record.removeEntry(key: "v")
        #expect(RemoteBonjourTXT(txt: record) == nil)
    }

    @Test func txtWithAnOversizedIdIsRejected() {
        var record = NWTXTRecord()
        record["id"] = String(repeating: "a", count: RemoteBonjourService.maxServerIdBytes + 1)
        record["v"] = "1"
        #expect(RemoteBonjourTXT(txt: record) == nil)
    }

    @Test func serviceNameFallsBackWhenEmpty() {
        #expect(RemoteBonjourService.serviceName("") == "Alas")
        #expect(RemoteBonjourService.serviceName("  \n ") == "Alas")
        #expect(RemoteBonjourService.serviceName("  Nacho's Mac ") == "Nacho's Mac")
    }

    @Test func serviceNameIsCutToTheLabelLimitOnAScalarBoundary() {
        // 31 two-byte characters = 62 bytes; a 32nd would cross 63.
        let name = String(repeating: "é", count: 40)
        let bounded = RemoteBonjourService.serviceName(name)
        #expect(bounded.utf8.count <= RemoteBonjourService.maxServiceNameBytes)
        #expect(bounded == String(repeating: "é", count: 31))
        let ascii = String(repeating: "x", count: 100)
        #expect(RemoteBonjourService.serviceName(ascii).utf8.count == RemoteBonjourService.maxServiceNameBytes)
    }

    private func remote(enabled: Bool, federation: Bool, discoverable: Bool) -> AppConfig.Remote {
        AppConfig.Remote(enabled: enabled, serverId: "srv-a",
                         federationEnabled: federation, discoverable: discoverable)
    }

    @Test func advertisesOnlyWhenTheServerFederationAndDiscoveryAreAllOn() {
        let advertised = RemoteBonjourAdvertisement.forSettings(
            remote(enabled: true, federation: true, discoverable: true), displayName: "Mac A", model: "Mac16,6")
        #expect(advertised?.txt.serverId == "srv-a")
        #expect(advertised?.displayName == "Mac A")
        #expect(advertised?.txt.model == "Mac16,6")

        // Any one of the three off withdraws the record.
        #expect(RemoteBonjourAdvertisement.forSettings(
            remote(enabled: false, federation: true, discoverable: true), displayName: "Mac A", model: nil) == nil)
        #expect(RemoteBonjourAdvertisement.forSettings(
            remote(enabled: true, federation: false, discoverable: true), displayName: "Mac A", model: nil) == nil)
        #expect(RemoteBonjourAdvertisement.forSettings(
            remote(enabled: true, federation: true, discoverable: false), displayName: "Mac A", model: nil) == nil)
    }
}
