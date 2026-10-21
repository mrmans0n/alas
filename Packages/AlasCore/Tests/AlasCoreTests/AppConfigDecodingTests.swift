import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

struct AppConfigDecodingTests {
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
        try JSONSerialization.data(withJSONObject: raw).write(to: file)

        try HostProfileWrite.update({ try HostSettingCatalog.named("host.port", in: $0).set("9999", in: &$0) }, file: file)

        let config = try #require(try PersistenceStore().readIfExists(AppConfig.self, from: file))
        #expect(config.host.port == 9999)
        #expect(config.themeId == "x")
        #expect(config.remote.enabled)
        #expect(config.terminal.fontSize == 17)
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect((written["someFutureSection"] as? [String: Any])?["flag"] as? Bool == true)
        #expect((written["remote"] as? [String: Any])?["someFutureKey"] as? String == "kept")
        #expect((written["worktrees"] as? [String: Any])?["defaultOrdering"] as? String == "someFutureMode")
    }
}
