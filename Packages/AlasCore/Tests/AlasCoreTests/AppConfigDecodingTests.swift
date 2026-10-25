import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

struct AppConfigDecodingTests {
    @Test func experimentalACP2OptInSurvivesConfigurationRoundTrip() throws {
        let config = try JSONDecoder().decode(
            AppConfig.self, from: Data(#"{"experimentalACP2Enabled":true}"#.utf8))
        let encoded = try JSONEncoder().encode(config)
        let saved = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(saved["experimentalACP2Enabled"] as? Bool == true)
    }

    @Test(arguments: [#"{}"#, #"{"experimentalACP2Enabled":null}"#, #"{"experimentalACP2Enabled":"true"}"#])
    func legacyOrMalformedConfigurationCannotOptIntoACP2(json: String) throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        let selection = ACPProtocolSelection(experimentalV2Enabled: config.experimentalACP2Enabled)
        #expect(!selection.experimentalV2Enabled)
        #expect(selection.requestedVersion == .v1)
    }

    @Test func computerUseSectionDefaultsOffAndRoundTrips() throws {
        let absent = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"remote":{"enabled":true}}"#.utf8))
        #expect(absent.computerUse.enabled == false)
        var config = absent
        config.computerUse.enabled = true
        let reloaded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(reloaded.computerUse.enabled)

        let enabledOnly = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"computerUse":{"enabled":true}}"#.utf8))
        #expect(enabledOnly.computerUse.enabled)
        config.computerUse.alwaysAllowedApps = ["com.apple.Notes"]
        let withApps = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(withApps.computerUse.alwaysAllowedApps == ["com.apple.Notes"])
    }

    @Test func legacySeeOnlyGrantsAreDropped() throws {
        let legacy = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"computerUse":{"enabled":true,"alwaysAllowedBundleIDs":["com.apple.Notes"]}}"#.utf8)
        )
        #expect(legacy.computerUse.enabled)
        #expect(legacy.computerUse.alwaysAllowedApps.isEmpty)
        let reencoded = try String(decoding: JSONEncoder().encode(legacy), as: UTF8.self)
        #expect(!reencoded.contains("alwaysAllowedBundleIDs"))
    }

    /// A hand-written `app.json` names only what it changes: everything else
    /// is the default, not a reason to drop the whole file.
    @Test(arguments: [
        #"{"remote":{"enabled":true}}"#,
        #"{"remote":{"enabled":true},"general":{"autoUpdate":false},"worktrees":{"baseBranch":"trunk"},"terminal":{"fontSize":15}}"#,
    ])
    func aPartialFileKeepsWhatItSetsAndDefaultsTheRest(_ json: String) throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.remote.enabled)
        let defaults = AppConfig.defaults
        #expect(config.themeId == defaults.themeId)
        #expect(config.sidebarWidth == defaults.sidebarWidth)
        #expect(config.harness == defaults.harness)
        if json.contains("general") {
            #expect(!config.general.autoUpdate)
            #expect(config.general.updateChannel == defaults.general.updateChannel)
            #expect(config.worktrees.baseBranch == "trunk")
            #expect(config.worktrees.rootPath == defaults.worktrees.rootPath)
            #expect(config.terminal.fontSize == 15)
            #expect(config.terminal.shell == defaults.terminal.shell)
        } else {
            #expect(config.general == defaults.general)
            #expect(config.worktrees == defaults.worktrees)
        }
    }

    /// The full file the app writes still reads back as it was.
    @Test func aWrittenFileReadsBackUnchanged() throws {
        var config = AppConfig.defaults
        config.themeId = "light"
        config.general.confirmQuit = false
        config.worktrees.fetchIntervalMinutes = 30
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }

    @Test(arguments: [
        (nil as HostReachability?, false, false, nil as HostRemoteListen?),
        (nil, true, false, HostRemoteListen(port: 8765, loopbackOnly: true, tailscaleServe: false)),
        (nil, true, true, HostRemoteListen(port: 8765, loopbackOnly: true, tailscaleServe: true)),
        (.lan, false, false, HostRemoteListen(port: 8765, loopbackOnly: false, tailscaleServe: false)),
        (.off, true, false, nil),
        (.loopback, true, true, HostRemoteListen(port: 8765, loopbackOnly: true, tailscaleServe: false)),
    ])
    func resolvesReachability(
        reachability: HostReachability?, enabled: Bool, serve: Bool, expected: HostRemoteListen?
    ) {
        var config = AppConfig.defaults
        config.host.reachability = reachability
        config.remote.enabled = enabled
        config.remote.tailscaleServe = serve
        #expect(config.hostRemoteListen == expected)
    }

    @Test func hostSectionAbsentKeepsSharedRemoteBehavior() throws {
        let json = #"{"remote":{"enabled":true,"port":9000}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.host == HostSettings())
        #expect(config.hostPort == 9000)
        #expect(config.hostReachability == .loopback)
    }

    @Test func hostSectionRoundTrips() throws {
        var config = AppConfig.defaults
        config.host = HostSettings(reachability: .lan, port: 18765)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.host == config.host)

        let bad = #"{"host":{"reachability":"wide-open","port":1234}}"#
        let lenient = try JSONDecoder().decode(AppConfig.self, from: Data(bad.utf8))
        #expect(lenient.host == HostSettings(reachability: Optional<HostReachability>.none, port: 1234))
    }

    @Test func writeKeepsUntouchedSettings() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("alas-write-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var seed = AppConfig.defaults
        seed.themeId = "x"
        seed.remote.enabled = true
        seed.terminal.fontSize = 17
        seed.agents.registry = ["acme", "other"].map {
            ACPRegistryInstalledAgent(
                registryID: $0, displayName: $0, version: "1", command: "\($0)-acp",
                arguments: [], environment: [:], isEnabled: true
            )
        }
        try PersistenceStore().write(seed, to: file)
        // Keys a newer app wrote that this build does not model.
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        raw["someFutureSection"] = ["flag": true]
        var remote = try #require(raw["remote"] as? [String: Any])
        remote["someFutureKey"] = "kept"
        raw["remote"] = remote
        var worktrees = try #require(raw["worktrees"] as? [String: Any])
        worktrees["defaultOrdering"] = "someFutureMode"
        raw["worktrees"] = worktrees
        var agents = try #require(raw["agents"] as? [String: Any])
        agents["registry"] = try #require(agents["registry"] as? [[String: Any]]).map { $0.merging(["someFutureField": 1]) { $1 } }
        raw["agents"] = agents
        try JSONSerialization.data(withJSONObject: raw).write(to: file)

        try HostProfileWrite.update({ try HostSettingCatalog.named("host.port", in: $0).set("9999", in: &$0) }, file: file)
        try HostProfileWrite.update({ try HostSettingCatalog.named("agents.acme.enabled", in: $0).set("false", in: &$0) }, file: file)

        let config = try #require(try PersistenceStore().readIfExists(AppConfig.self, from: file))
        #expect(config.host.port == 9999)
        #expect(config.themeId == "x")
        #expect(config.remote.enabled)
        #expect(config.terminal.fontSize == 17)
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect((written["someFutureSection"] as? [String: Any])?["flag"] as? Bool == true)
        #expect((written["remote"] as? [String: Any])?["someFutureKey"] as? String == "kept")
        #expect((written["worktrees"] as? [String: Any])?["defaultOrdering"] as? String == "someFutureMode")
        #expect(config.agents.registry.map(\.isEnabled) == [false, true])
        let registry = (written["agents"] as? [String: Any])?["registry"] as? [[String: Any]]
        #expect(registry?.map { $0["someFutureField"] as? Int } == [1, 1])
    }

    /// Installing a registry agent adds it; reinstalling one, as an update
    /// does, replaces its record and keeps whether the user turned it off.
    @Test func installingARegistryAgentAddsItAndAReinstallKeepsItsEnabledState() {
        func agent(_ version: String, enabled: Bool = true) -> ACPRegistryInstalledAgent {
            ACPRegistryInstalledAgent(
                registryID: "acme", displayName: "Acme", version: version,
                command: "acme-acp", arguments: [], environment: [:], isEnabled: enabled
            )
        }
        var agents = AppConfig.defaults.agents
        agents.installRegistryAgent(agent("1"))
        #expect(agents.registry.map(\.version) == ["1"])
        agents.registry[0].isEnabled = false
        agents.installRegistryAgent(agent("2"))
        #expect(agents.registry.map(\.version) == ["2"])
        #expect(agents.registry.map(\.isEnabled) == [false])
        agents.uninstallRegistryAgent(registryID: "acme")
        #expect(agents.registry.isEmpty)
    }

    /// Two `alas-host` commands writing at once, such as two `registry
    /// install`s, each keep their change: a write reads the profile only once
    /// the previous one has saved it.
    @Test func concurrentProfileWritesKeepEveryChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("app.json")
        let writers = 16
        DispatchQueue.concurrentPerform(iterations: writers) { index in
            try? HostProfileWrite.update({
                $0.agents.installRegistryAgent(ACPRegistryInstalledAgent(
                    registryID: "agent-\(index)", displayName: "Agent \(index)", version: "1",
                    command: "agent", arguments: [], environment: [:], isEnabled: true
                ))
            }, file: file)
        }
        let saved = try #require(try PersistenceStore().readIfExists(AppConfig.self, from: file))
        #expect(Set(saved.agents.registry.map(\.registryID)) == Set((0 ..< writers).map { "agent-\($0)" }))
    }
}
