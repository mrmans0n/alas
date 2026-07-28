import Testing
import Foundation
@testable import Alas

struct AppConfigChangesTests {
    @Test func defaultsHaveNoneToolAndNonEmptyPrompt() {
        #expect(AppConfig.defaults.changes.aiToolId == "none")
        #expect(!AppConfig.defaults.changes.prompt.isEmpty)
    }

    @Test func defaultsHaveNonEmptyReviewRequestPrompt() {
        #expect(!AppConfig.defaults.changes.reviewRequestPrompt.isEmpty)
        #expect(AppConfig.defaults.changes.reviewRequestPrompt.contains("Line 1: concise PR title"))
        #expect(AppConfig.defaults.changes.reviewRequestPrompt.contains("## Summary"))
        #expect(AppConfig.defaults.changes.reviewRequestPrompt.contains("## Testing"))
        #expect(AppConfig.defaults.changes.reviewRequestPrompt.contains("Do not mention uncommitted working tree changes"))
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

    @Test func decodesLegacyChangesWithoutReviewRequestPrompt() throws {
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
            "aiToolId": "none",
            "prompt": "commit prompt",
            "mergeBulkResolvePrompt": "bulk",
            "mergeSingleResolvePrompt": "single",
            "trackUpstreamForCommits": true
          }
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.changes.reviewRequestPrompt == AppConfig.defaultReviewRequestPrompt)
    }

    @Test func roundTripsReviewRequestPrompt() throws {
        var cfg = AppConfig.defaults
        cfg.changes.reviewRequestPrompt = "custom review request prompt"
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.changes.reviewRequestPrompt == "custom review request prompt")
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
        #expect(cfg.changes.comparisonMode == .auto)
    }

    private func decodeChanges(mutating: ([String: Any]) -> [String: Any]) throws -> AppConfig.Changes {
        let data = try JSONEncoder().encode(AppConfig.defaults)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj["changes"] = mutating(obj["changes"] as! [String: Any])
        let mutated = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(AppConfig.self, from: mutated).changes
    }

    @Test func migratesLegacyTrackUpstreamTrueToBranchUpstream() throws {
        let changes = try decodeChanges { var c = $0
        c.removeValue(forKey: "comparisonMode")
        c["trackUpstreamForCommits"] = true
        return c }
        #expect(changes.comparisonMode == .branchUpstream)
    }

    @Test func migratesLegacyTrackUpstreamFalseToAuto() throws {
        let changes = try decodeChanges { var c = $0
        c.removeValue(forKey: "comparisonMode")
        c["trackUpstreamForCommits"] = false
        return c }
        #expect(changes.comparisonMode == .auto)
    }

    @Test func defaultsToAutoWhenNeitherKeyPresent() throws {
        let changes = try decodeChanges { var c = $0
        c.removeValue(forKey: "comparisonMode")
        c.removeValue(forKey: "trackUpstreamForCommits")
        return c }
        #expect(changes.comparisonMode == .auto)
    }

    @Test func explicitComparisonModeWinsOverLegacyBool() throws {
        let changes = try decodeChanges { var c = $0
        c["comparisonMode"] = "manual"
        c["trackUpstreamForCommits"] = true
        return c }
        #expect(changes.comparisonMode == .manual)
    }

    @Test func defaultsHaveDiffDisplayPreferences() {
        #expect(AppConfig.defaults.changes.diffLayoutMode == .split)
        #expect(AppConfig.defaults.changes.diffShowWhitespace == false)
    }

    @Test func decodesLegacyChangesWithoutDiffDisplayPreferences() throws {
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
            "reviewRequestPrompt": "r",
            "mergeBulkResolvePrompt": "b",
            "mergeSingleResolvePrompt": "s",
            "trackUpstreamForCommits": true
          }
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.changes.diffLayoutMode == .split)
        #expect(cfg.changes.diffShowWhitespace == false)
    }

    @Test func roundTripsDiffDisplayPreferences() throws {
        var cfg = AppConfig.defaults
        cfg.changes.diffLayoutMode = .stacked
        cfg.changes.diffShowWhitespace = true
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.changes.diffLayoutMode == .stacked)
        #expect(decoded.changes.diffShowWhitespace == true)
    }

    @Test func ignoresAndDropsLegacyDiffWrapLines() throws {
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfig.defaults))
                as? [String: Any]
        )
        var legacy = json
        var changes = try #require(legacy["changes"] as? [String: Any])
        changes["diffWrapLines"] = true
        legacy["changes"] = changes

        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacyData)
        let encodedData = try JSONEncoder().encode(decoded)
        let encoded = try #require(
            JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
        )
        let encodedChanges = try #require(encoded["changes"] as? [String: Any])

        #expect(encodedChanges["diffWrapLines"] == nil)
    }
}
