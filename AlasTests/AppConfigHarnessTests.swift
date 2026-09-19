import Foundation
import Testing
@testable import Alas

@Suite("AppConfig harness fields")
struct AppConfigHarnessTests {
    @Test("defaults have empty dismissedHookInstallNudges")
    func defaultsEmpty() {
        #expect(AppConfig.defaults.harness.dismissedHookInstallNudges == [])
    }

    @Test("legacy config without dismissedHookInstallNudges decodes as empty")
    func legacyDecode() throws {
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
        #expect(cfg.harness.dismissedHookInstallNudges == [])
    }

    @Test("collapse finished tool calls defaults off and decodes off when the key is missing")
    func collapseFinishedToolCallsDefaultsOff() throws {
        #expect(!AppConfig.defaults.harness.acpCollapseFinishedToolCalls)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfig.defaults)) as? [String: Any])
        var harness = try #require(object["harness"] as? [String: Any])
        harness.removeValue(forKey: "acpCollapseFinishedToolCalls")
        object["harness"] = harness
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!decoded.harness.acpCollapseFinishedToolCalls)
    }

    @Test("collapse finished tool calls round-trips when enabled")
    func collapseFinishedToolCallsRoundTrip() throws {
        var cfg = AppConfig.defaults
        cfg.harness.acpCollapseFinishedToolCalls = true
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.harness.acpCollapseFinishedToolCalls)
    }

    @Test("populated values round-trip")
    func roundTrip() throws {
        var cfg = AppConfig.defaults
        cfg.harness.dismissedHookInstallNudges = [AgentKind.claude.rawValue, AgentKind.codex.rawValue]
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.harness.dismissedHookInstallNudges == [AgentKind.claude.rawValue, AgentKind.codex.rawValue])
    }
}
