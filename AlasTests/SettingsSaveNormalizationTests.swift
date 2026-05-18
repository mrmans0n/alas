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
}
