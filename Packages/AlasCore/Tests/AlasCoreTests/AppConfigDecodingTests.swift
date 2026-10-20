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
}
