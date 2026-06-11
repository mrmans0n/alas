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

    @Test func defaultsHaveChatAppearance() {
        #expect(AppConfig.defaults.agents.chatFontFamily == "")
        #expect(AppConfig.defaults.agents.chatFontSize == 13)
    }

    @Test func decodesLegacyConfigWithoutAgentsKey() throws {
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
        #expect(cfg.agents.builtinState.isEmpty)
        #expect(cfg.agents.custom.isEmpty)
        #expect(cfg.agents.worktreeAutoLaunch.agentId == nil)
    }

    @Test func roundTripsBuiltinStateAndCustoms() throws {
        var cfg = AppConfig.defaults
        cfg.agents.builtinState = [
            "codex": BuiltinAgentState(isEnabled: false, binaryOverride: nil),
            "claude": BuiltinAgentState(isEnabled: true, binaryOverride: "/opt/local/bin/claude", extraTerminalArgs: ["--model", "sonnet"]),
        ]
        cfg.agents.custom = [
            AgentDefinition(
                id: "uuid-1", displayName: "Mine",
                binary: "~/bin/mine", binaryOverride: nil,
                promptModeArgs: ["-p"], bypassPermissionsFlag: "--yolo",
                extraTerminalArgs: ["--verbose"],
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
        #expect(decoded.agents.builtinState["claude"]?.extraTerminalArgs == ["--model", "sonnet"])
        #expect(decoded.agents.custom.first?.extraTerminalArgs == ["--verbose"])
    }

    @Test func decodesBuiltinStateWithoutExtraTerminalArgs() throws {
        let json = """
        {"isEnabled": true, "binaryOverride": "/usr/local/bin/claude"}
        """
        let state = try JSONDecoder().decode(BuiltinAgentState.self, from: Data(json.utf8))
        #expect(state.isEnabled == true)
        #expect(state.binaryOverride == "/usr/local/bin/claude")
        #expect(state.extraTerminalArgs == nil)
    }

    @Test func decodesPartialAgentsBlockWithMissingInnerFields() throws {
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
          "agents": {}
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.agents.builtinState.isEmpty)
        #expect(cfg.agents.custom.isEmpty)
        #expect(cfg.agents.worktreeAutoLaunch.agentId == nil)
        #expect(cfg.agents.worktreeAutoLaunch.useBypassPermissions == false)
    }

    @Test func decodesPartialAgentsBlockWithMissingChatAppearance() throws {
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
          "agents": {}
        }
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.agents.chatFontFamily == "")
        #expect(cfg.agents.chatFontSize == 13)
    }

    @Test func decodesChatFontSizeWithClamp() throws {
        var low = AppConfig.defaults
        low.agents.chatFontSize = 2
        let lowData = try JSONEncoder().encode(low)
        let lowDecoded = try JSONDecoder().decode(AppConfig.self, from: lowData)
        #expect(lowDecoded.agents.chatFontSize == 8)

        var high = AppConfig.defaults
        high.agents.chatFontSize = 200
        let highData = try JSONEncoder().encode(high)
        let highDecoded = try JSONDecoder().decode(AppConfig.self, from: highData)
        #expect(highDecoded.agents.chatFontSize == 64)
    }

    @Test func roundTripsChatAppearance() throws {
        var cfg = AppConfig.defaults
        cfg.agents.chatFontFamily = "SF Mono"
        cfg.agents.chatFontSize = 16

        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.agents.chatFontFamily == "SF Mono")
        #expect(decoded.agents.chatFontSize == 16)
    }
}
