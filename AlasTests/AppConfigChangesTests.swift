import Testing
import Foundation
@testable import Alas

struct AppConfigChangesTests {
    @Test func defaultsHaveNoneToolAndNonEmptyPrompt() {
        #expect(AppConfig.defaults.changes.aiToolId == "none")
        #expect(!AppConfig.defaults.changes.prompt.isEmpty)
    }

    @Test func decodesLegacyConfigWithoutChangesKey() throws {
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
            "rootPath": "~/.alas/worktrees",
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
          "harness": {"notifyOnFinish": true, "notifyOnAwaiting": true}
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.changes.aiToolId == "none")
        #expect(!cfg.changes.prompt.isEmpty)
    }

    @Test func roundTripsChangesSubstruct() throws {
        var cfg = AppConfig.defaults
        cfg.changes.aiToolId = "claude"
        cfg.changes.prompt = "custom prompt"
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.changes.aiToolId == "claude")
        #expect(decoded.changes.prompt == "custom prompt")
    }

    @Test func defaultsHaveTrackUpstreamForCommitsOff() {
        #expect(AppConfig.defaults.changes.trackUpstreamForCommits == false)
    }

    @Test func decodesLegacyChangesWithoutTrackUpstreamForCommits() throws {
        // A config blob with a `changes` section that predates the new key.
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
            "rootPath": "~/.alas/worktrees",
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
          "harness": {"notifyOnFinish": true, "notifyOnAwaiting": true},
          "changes": {
            "aiToolId": "claude",
            "prompt": "p",
            "mergeBulkResolvePrompt": "b",
            "mergeSingleResolvePrompt": "s"
          }
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.changes.aiToolId == "claude")
        #expect(cfg.changes.trackUpstreamForCommits == false)
    }

    @Test func roundTripsTrackUpstreamForCommits() throws {
        var cfg = AppConfig.defaults
        cfg.changes.trackUpstreamForCommits = true
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.changes.trackUpstreamForCommits == true)
    }
}
