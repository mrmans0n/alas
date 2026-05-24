import Testing
import Foundation
@testable import Alas

struct AppConfigSidebarChromeOverridesTests {
    @Test func defaultsContainsBothBundledThemes() {
        let defaults = SidebarChromeOverride.bundledDefaults
        #expect(defaults["cool-slate"]?.backgroundOpacity == 0.25)
        #expect(defaults["cool-slate"]?.textContrast == 0.15)
        #expect(defaults["light"]?.backgroundOpacity == 0.25)
        #expect(defaults["light"]?.textContrast == 0.15)
    }

    @Test func resolveFallsBackToBundledDefaults() {
        let cfg = AppConfig.defaults
        let resolved = cfg.sidebarChromeOverride(forThemeId: "cool-slate")
        #expect(resolved.backgroundOpacity == 0.25)
        #expect(resolved.textContrast == 0.15)
    }

    @Test func resolveUnknownThemeFallsBackToZeroSafeValue() {
        let cfg = AppConfig.defaults
        let resolved = cfg.sidebarChromeOverride(forThemeId: "no-such-theme")
        #expect(resolved.backgroundOpacity == 0.0)
        #expect(resolved.textContrast == 0.0)
    }

    @Test func codableRoundTripPreservesOverrides() throws {
        var cfg = AppConfig.defaults
        cfg.sidebarChromeOverrides["cool-slate"] = SidebarChromeOverride(
            backgroundOpacity: 0.7, textContrast: 0.5
        )
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.sidebarChromeOverrides["cool-slate"]?.backgroundOpacity == 0.7)
        #expect(decoded.sidebarChromeOverrides["cool-slate"]?.textContrast == 0.5)
    }

    @Test func decodingOlderConfigWithoutOverridesProducesEmptyDict() throws {
        let json = """
        {
            "themeId": "cool-slate",
            "accent": "teal",
            "matchSystemTheme": false,
            "sidebarMaterial": "appKitSidebar",
            "sidebarWidth": 244,
            "rightPaneWidth": 320,
            "rightPaneVisible": true,
            "commitDetailSplitRatio": 0.32,
            "general": {"launchAtLogin":false,"closeToTray":true,"confirmQuit":true,"autoUpdate":true,"updateChannel":"Stable","crashReports":false,"usageAnalytics":false},
            "worktrees": {"rootPath":"~/x","pathTemplate":"{worktreeRoot}/{repo}/{branch}","branchPrefix":"f/","baseBranch":"main","trackUpstream":true,"deleteBranchOnRemove":true,"autoFetch":true,"fetchIntervalMinutes":5,"pruneStale":false},
            "terminal": {"shell":"/bin/zsh","workingDirectory":"worktreeRoot","startupScript":"","worktreeCreateScript":"","inheritParentEnv":true,"fontFamily":"JetBrains Mono","fontSize":13,"cursorStyle":"beam","cursorBlink":true,"scrollbackLines":10000,"bell":"visual"},
            "harness": {"notifyOnFinish":true,"notifyOnAwaiting":true},
            "code": {"fontFamily":"SF Mono","fontSize":13,"formatOnSave":true,"languageServers":[],"dismissedInstallNudges":[],"userDefinedRecipes":{}},
            "markdown": {"defaultViewMode":"editor"},
            "changes": {"aiToolId":"none","prompt":""},
            "agents": {"builtinState":{},"custom":[],"worktreeAutoLaunch":{"agentId":null,"useBypassPermissions":false}},
            "files": {"showIgnored":true}
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.sidebarChromeOverrides.isEmpty)
    }
}
