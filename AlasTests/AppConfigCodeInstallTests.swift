import Foundation
import Testing
@testable import Alas

@Suite("AppConfig install nudge fields")
struct AppConfigCodeInstallTests {
    @Test("defaults have empty dismissedInstallNudges and userDefinedRecipes")
    func defaultsEmpty() {
        #expect(AppConfig.defaults.code.dismissedInstallNudges == [])
        #expect(AppConfig.defaults.code.userDefinedRecipes == [:])
    }

    @Test("legacy config without these keys decodes with empty defaults")
    func legacyDecode() throws {
        // Minimal config omitting dismissedInstallNudges and userDefinedRecipes
        let json = """
        {
          "themeId": "cool-slate",
          "accent": "teal",
          "density": "comfortable",
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
          "harness": {"notifyOnFinish": true},
          "code": {"fontFamily": "SF Mono", "fontSize": 13, "languageServers": []}
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.code.dismissedInstallNudges == [])
        #expect(cfg.code.userDefinedRecipes == [:])
    }

    @Test("populated values round-trip")
    func roundTrip() throws {
        var cfg = AppConfig.defaults
        cfg.code.dismissedInstallNudges = ["rust", "go"]
        cfg.code.userDefinedRecipes = [
            "zig": [InstallRecipe(installer: .brew, package: "zls")]
        ]
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.code.dismissedInstallNudges == ["rust", "go"])
        #expect(decoded.code.userDefinedRecipes["zig"]?.first?.package == "zls")
        #expect(decoded.code.userDefinedRecipes["zig"]?.first?.installer == .brew)
    }
}
