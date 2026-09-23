import Testing
import Foundation
@testable import Alas

struct RemoteConfigTests {
    @Test func remoteConfigDefaultsOff() {
        let cfg = AppConfig.defaults
        #expect(cfg.remote.enabled == false)
        #expect(cfg.remote.port == 0)
    }

    @Test func remoteConfigDefaultsHostFieldsEmpty() {
        let cfg = AppConfig.defaults
        #expect(cfg.remote.allowedHosts == [])
        #expect(cfg.remote.preferredAdvertisedHost == nil)
    }

    @Test func remoteConfigRoundTripsJSON() throws {
        var cfg = AppConfig.defaults
        cfg.remote.enabled = true
        cfg.remote.port = 8765
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(back.remote.enabled == true)
        #expect(back.remote.port == 8765)
    }

    @Test func remoteConfigHostFieldsRoundTripJSON() throws {
        var cfg = AppConfig.defaults
        cfg.remote.enabled = true
        cfg.remote.port = 8765
        cfg.remote.allowedHosts = ["nacho-mbp.local", "100.88.1.20"]
        cfg.remote.preferredAdvertisedHost = "100.88.1.20"

        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(back.remote.enabled == true)
        #expect(back.remote.port == 8765)
        #expect(back.remote.allowedHosts == ["nacho-mbp.local", "100.88.1.20"])
        #expect(back.remote.preferredAdvertisedHost == "100.88.1.20")
    }

    /// Existing on-disk configs predate the `remote` key. Encoding the
    /// defaults, stripping `remote`, and decoding must still succeed with
    /// `enabled == false` — otherwise every current user's config fails to load.
    @Test func oldConfigWithoutRemoteKeyDecodesDisabled() throws {
        let data = try JSONEncoder().encode(AppConfig.defaults)
        var json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        json.removeValue(forKey: "remote")
        #expect(json["remote"] == nil)
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder().decode(AppConfig.self, from: stripped)
        #expect(back.remote.enabled == false)
        #expect(back.remote.port == 0)
    }

    @Test func oldRemoteConfigWithoutHostFieldsDecodesDefaults() throws {
        let data = try JSONEncoder().encode(AppConfig.defaults)
        var json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var remote = try #require(json["remote"] as? [String: Any])
        remote.removeValue(forKey: "allowedHosts")
        remote.removeValue(forKey: "preferredAdvertisedHost")
        json["remote"] = remote

        let stripped = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder().decode(AppConfig.self, from: stripped)

        #expect(back.remote.allowedHosts == [])
        #expect(back.remote.preferredAdvertisedHost == nil)
    }

    @Test func ensureServerIdAssignsOnceAndStaysStable() {
        var remote = AppConfig.Remote()
        #expect(remote.ensureServerId() == true)
        let first = remote.serverId
        #expect(!first.isEmpty)
        #expect(remote.ensureServerId() == false)
        #expect(remote.serverId == first)
    }

    @Test func remoteConfigIdentityFieldsRoundTripJSON() throws {
        var cfg = AppConfig.defaults
        cfg.remote.allowedOrigins = ["https://app.alas.build"]
        cfg.remote.serverId = "srv-1"
        cfg.remote.displayName = "Studio Mac"
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(back.remote.allowedOrigins == ["https://app.alas.build"])
        #expect(back.remote.serverId == "srv-1")
        #expect(back.remote.displayName == "Studio Mac")
    }

    @Test func remoteHubFlagIsNotPersistedAndLegacySettingIsIgnored() throws {
        let data = try JSONEncoder().encode(AppConfig.defaults)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var remote = try #require(json["remote"] as? [String: Any])
        #expect(remote["hubEnabled"] == nil)

        remote["hubEnabled"] = false
        json["remote"] = remote
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacyData)
        let roundTrip = try JSONEncoder().encode(decoded)
        let roundTripJSON = try #require(try JSONSerialization.jsonObject(with: roundTrip) as? [String: Any])
        let roundTripRemote = try #require(roundTripJSON["remote"] as? [String: Any])
        #expect(roundTripRemote["hubEnabled"] == nil)
    }

    @Test func oldRemoteConfigWithoutIdentityFieldsDecodesDefaults() throws {
        let data = try JSONEncoder().encode(AppConfig.defaults)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var remote = try #require(json["remote"] as? [String: Any])
        for key in ["allowedOrigins", "serverId", "displayName"] { remote.removeValue(forKey: key) }
        json["remote"] = remote
        let back = try JSONDecoder().decode(AppConfig.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(back.remote.allowedOrigins == [])
        #expect(back.remote.serverId == "")
        #expect(back.remote.displayName == "")
    }

    @Test func federationDefaultsOffAndRoundTrips() throws {
        #expect(AppConfig.defaults.remote.federationEnabled == false)
        var cfg = AppConfig.defaults
        cfg.remote.federationEnabled = true
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(cfg))
        #expect(back.remote.federationEnabled == true)
    }

    @Test func oldRemoteConfigWithoutFederationKeyDecodesFalse() throws {
        let data = try JSONEncoder().encode(AppConfig.defaults)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var remote = try #require(json["remote"] as? [String: Any])
        remote.removeValue(forKey: "federationEnabled")
        json["remote"] = remote
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.remote.federationEnabled == false)
    }

    @Test func discoverableDefaultsOffAndRoundTrips() throws {
        #expect(AppConfig.defaults.remote.discoverable == false)
        var cfg = AppConfig.defaults
        cfg.remote.discoverable = true
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(cfg))
        #expect(back.remote.discoverable == true)
    }

    @Test func oldRemoteConfigWithoutDiscoverableKeyDecodesFalse() throws {
        let data = try JSONEncoder().encode(AppConfig.defaults)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var remote = try #require(json["remote"] as? [String: Any])
        remote.removeValue(forKey: "discoverable")
        json["remote"] = remote
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.remote.discoverable == false)
    }
}
