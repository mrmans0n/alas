import Testing
import Foundation
@testable import Alas

struct AppConfigAgentsCodingTests {
    @Test func defaultsHaveEmptyAgentsBlock() {
        #expect(AppConfig.defaults.agents.builtinState.isEmpty)
        #expect(AppConfig.defaults.agents.custom.isEmpty)
        #expect(AppConfig.defaults.agents.worktreeAutoLaunch.agentId == nil)
        #expect(AppConfig.defaults.agents.worktreeAutoLaunch.useBypassPermissions == false)
    }

    @Test func decodesLegacyConfigWithoutAgentsKey() throws {
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
        #expect(cfg.agents.builtinState.isEmpty)
        #expect(cfg.agents.custom.isEmpty)
        #expect(cfg.agents.worktreeAutoLaunch.agentId == nil)
    }

    @Test func roundTripsBuiltinStateAndCustoms() throws {
        var cfg = AppConfig.defaults
        cfg.agents.builtinState = [
            "codex": BuiltinAgentState(isEnabled: false, binaryOverride: nil),
            "claude": BuiltinAgentState(isEnabled: true, binaryOverride: "/opt/local/bin/claude"),
        ]
        cfg.agents.custom = [
            AgentDefinition(
                id: "uuid-1", displayName: "Mine",
                binary: "~/bin/mine", binaryOverride: nil,
                promptModeArgs: ["-p"], bypassPermissionsFlag: "--yolo",
                isBuiltin: false, isEnabled: true,
                builtinLogoAssetName: nil
            )
        ]
        cfg.agents.worktreeAutoLaunch = AppConfig.WorktreeAutoLaunch(
            agentId: "claude", useBypassPermissions: true
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.agents.builtinState["codex"]?.isEnabled == false)
        #expect(decoded.agents.builtinState["claude"]?.binaryOverride == "/opt/local/bin/claude")
        // Full-struct equality catches any future field that's omitted
        // from Codable conformance (or renamed without updating CodingKeys).
        #expect(decoded.agents.custom.first == cfg.agents.custom.first)
        #expect(decoded.agents.custom.first?.id == "uuid-1")
        #expect(decoded.agents.worktreeAutoLaunch.agentId == "claude")
        #expect(decoded.agents.worktreeAutoLaunch.useBypassPermissions == true)
    }

    @Test func decodesPartialAgentsBlockWithMissingInnerFields() throws {
        // `agents` key is present but empty — exercises the `if let
        // agentsContainer = ...` branch where each inner field's `try?`
        // decode falls back to its default independently.
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
          "agents": {}
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.agents.builtinState.isEmpty)
        #expect(cfg.agents.custom.isEmpty)
        #expect(cfg.agents.worktreeAutoLaunch.agentId == nil)
        #expect(cfg.agents.worktreeAutoLaunch.useBypassPermissions == false)
    }
}
