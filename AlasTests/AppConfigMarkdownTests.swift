import Testing
import Foundation
@testable import Alas

struct AppConfigMarkdownTests {
    @Test func defaultsHaveMarkdownEditorMode() {
        #expect(AppConfig.defaults.markdown.defaultViewMode == .editor)
    }

    @Test func decodesLegacyConfigWithoutMarkdownKey() throws {
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
        #expect(cfg.markdown.defaultViewMode == .editor)
    }

    @Test func roundTripsEachDefaultViewMode() throws {
        for mode in MarkdownViewMode.allCases {
            var cfg = AppConfig.defaults
            cfg.markdown.defaultViewMode = mode
            let data = try JSONEncoder().encode(cfg)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            #expect(decoded.markdown.defaultViewMode == mode)
        }
    }
}
