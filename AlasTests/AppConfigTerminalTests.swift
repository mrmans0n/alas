import Testing
import Foundation
@testable import Alas

struct AppConfigTerminalTests {
    @Test func defaultsHaveKeepSessionsAliveOn() {
        #expect(AppConfig.defaults.terminal.keepSessionsAlive == true)
    }

    @Test func decodesLegacyTerminalConfigWithoutKeepSessionsAliveKey() throws {
        // Legacy terminal block with no `keepSessionsAlive` key — matches
        // configs written before this setting existed. Decode must default
        // to true so users upgrading from PR #317 see no behavior change.
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
        #expect(cfg.terminal.keepSessionsAlive == true)
    }

    @Test func roundTripsKeepSessionsAlive() throws {
        for value in [true, false] {
            var cfg = AppConfig.defaults
            cfg.terminal.keepSessionsAlive = value
            let data = try JSONEncoder().encode(cfg)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            #expect(decoded.terminal.keepSessionsAlive == value)
        }
    }
}
