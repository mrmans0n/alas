import Foundation
import Testing
@testable import Alas

struct SettingsSaveNormalizationTests {
    @Test func customAgentSaveTrimsPersistedCommandFields() {
        let agent = AgentDefinition(
            id: "custom",
            displayName: "  Custom Agent  ",
            binary: "  claude  ",
            binaryOverride: "  ignored  ",
            promptModeArgs: ["--print"],
            bypassPermissionsFlag: " --dangerously-skip-permissions ",
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )

        let normalized = agent.normalizedForSettingsSave()

        #expect(normalized.displayName == "Custom Agent")
        #expect(normalized.binary == "claude")
        #expect(normalized.binaryOverride == nil)
        #expect(normalized.bypassPermissionsFlag == "--dangerously-skip-permissions")
    }

    @Test func languageServerSaveTrimsPersistedCommandFields() {
        let entry = LanguageServerConfig(
            language: "  swift  ",
            extensions: ["swift"],
            command: "  sourcekit-lsp  ",
            args: [" --stdio ", "", "  --log  "],
            env: [:],
            rootMarkers: [" Package.swift ", "", "  .git  "],
            enabled: true
        )

        let normalized = entry.normalizedForSettingsSave()

        #expect(normalized.language == "swift")
        #expect(normalized.command == "sourcekit-lsp")
        #expect(normalized.args == ["--stdio", "--log"])
        #expect(normalized.rootMarkers == ["Package.swift", ".git"])
    }

    @Test func decodeMissingSyncTabTitleField() throws {
        let json = #"{"themeId":"cool-slate","accent":"teal","density":"comfortable","matchSystemTheme":false,"sidebarMaterial":"appKitSidebar","sidebarWidth":244,"rightPaneWidth":320,"rightPaneVisible":true,"sidebarVisible":true,"commitDetailSplitRatio":0.32,"general":{"launchAtLogin":false,"closeToTray":true,"confirmQuit":true,"autoUpdate":true,"updateChannel":"Stable","crashReports":false,"usageAnalytics":false},"worktrees":{"rootPath":"~/.alas/worktrees","pathTemplate":"{worktreeRoot}/{repo}/{branch}","branchPrefix":"feature/","baseBranch":"main","trackUpstream":true,"deleteBranchOnRemove":true,"autoFetch":true,"fetchIntervalMinutes":5,"pruneStale":false},"terminal":{"shell":"/bin/zsh","workingDirectory":"worktreeRoot","startupScript":"","worktreeCreateScript":"","inheritParentEnv":true,"fontFamily":"JetBrains Mono","fontSize":13,"cursorStyle":"beam","cursorBlink":true,"scrollbackLines":10000,"bell":"visual"},"harness":{"notifyOnFinish":true,"notifyOnAwaiting":true},"code":{"fontFamily":"SF Mono","fontSize":13,"formatOnSave":true,"languageServers":[],"dismissedInstallNudges":[],"userDefinedRecipes":{}},"markdown":{"defaultViewMode":"editor"},"changes":{"aiToolId":"none","prompt":"Hello"},"agents":{"builtinState":{},"custom":[],"worktreeAutoLaunch":{"agentId":null,"useBypassPermissions":false}},"files":{"showIgnored":true}}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.terminal.syncTabTitleWithTerminalTitle == false)
    }
}
