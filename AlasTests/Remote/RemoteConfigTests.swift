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
}
