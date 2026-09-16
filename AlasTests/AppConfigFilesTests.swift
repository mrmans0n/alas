import Testing
import Foundation
@testable import Alas

struct AppConfigFilesTests {
    @Test func bookmarksCollapseRoundTripsWithoutChangingHeight() throws {
        for collapsed in [true, false] {
            var config = AppConfig.defaults
            config.files.bookmarksPaneHeight = 210
            config.files.bookmarksCollapsed = collapsed
            let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
            #expect(decoded.files.bookmarksCollapsed == collapsed)
            #expect(decoded.files.bookmarksPaneHeight == 210)
        }
    }

    @Test func legacyFilesSettingsDefaultToExpanded() throws {
        let defaults = try JSONEncoder().encode(AppConfig.defaults)
        var legacy = try #require(JSONSerialization.jsonObject(with: defaults) as? [String: Any])
        legacy["files"] = ["showIgnored": false, "bookmarksPaneHeight": 210]
        let config = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!config.files.bookmarksCollapsed)
        #expect(config.files.bookmarksPaneHeight == 210)
        #expect(!config.files.showIgnored)
    }

    @Test func defaultsHaveShowIgnoredOn() {
        #expect(AppConfig.defaults.files.showIgnored == true)
    }

    @Test func decodesLegacyConfigWithoutFilesKey() throws {
        let json = """
        {
          "themeId": "cool-slate",
          "accent": "teal",
          "matchSystemTheme": false,
          "sidebarWidth": 244,
          "rightPaneWidth": 320,
          "rightPaneVisible": true,
          "general": {
            "launchAtLogin": false, "closeToTray": true, "confirmQuit": true,
            "autoUpdate": true, "updateChannel": "Stable",
            "crashReports": false, "usageAnalytics": false
          },
          "worktrees": {
            "rootPath": "~/code/.worktrees",
            "pathTemplate": "{worktreeRoot}/{repo}/{branch}",
            "branchPrefix": "feature/", "baseBranch": "main",
            "trackUpstream": true, "deleteBranchOnRemove": true,
            "autoFetch": true, "fetchIntervalMinutes": 5, "pruneStale": false
          },
          "terminal": {
            "shell": "/bin/zsh", "workingDirectory": "worktreeRoot",
            "startupScript": "", "worktreeCreateScript": "",
            "inheritParentEnv": true, "fontFamily": "JetBrains Mono",
            "fontSize": 13, "cursorStyle": "beam", "cursorBlink": true,
            "scrollbackLines": 10000, "bell": "visual"
          },
          "harness": {"notifyOnFinish": true}
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.files.showIgnored == true)
    }

    @Test func roundTripsFilesShowIgnored() throws {
        for value in [true, false] {
            var cfg = AppConfig.defaults
            cfg.files.showIgnored = value
            let data = try JSONEncoder().encode(cfg)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            #expect(decoded.files.showIgnored == value)
        }
    }
}
