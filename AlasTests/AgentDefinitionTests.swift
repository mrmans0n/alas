import Testing
import Foundation
@testable import Alas

struct AgentDefinitionTests {
    @Test func resolvedBinaryPrefersOverride() {
        let a = AgentDefinition(
            id: "x",
            displayName: "X",
            binary: "x-bin",
            binaryOverride: "/opt/local/bin/x-bin",
            promptModeArgs: ["-p"],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
        #expect(a.resolvedBinary == "/opt/local/bin/x-bin")
    }

    @Test func resolvedBinaryFallsBackToBinary() {
        let a = AgentDefinition(
            id: "x",
            displayName: "X",
            binary: "x-bin",
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
        #expect(a.resolvedBinary == "x-bin")
    }

    @Test func emptyOverrideStringTreatedAsAbsent() {
        // The Settings UI persists empty-string overrides as nil-equivalent
        // (empty trimmed string). resolvedBinary must not return "".
        let a = AgentDefinition(
            id: "x", displayName: "X", binary: "x-bin",
            binaryOverride: "   ",
            promptModeArgs: [], bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
        #expect(a.resolvedBinary == "x-bin")
    }

    @Test func resolvedBinaryExpandsTildeInOverride() {
        // /usr/bin/env doesn't tilde-expand, and shell-quoting in the
        // auto-launch path defeats interactive-shell expansion too.
        // resolvedBinary must hand back a path /usr/bin/env can stat.
        let a = AgentDefinition(
            id: "x", displayName: "X", binary: "x-bin",
            binaryOverride: "~/bin/x-bin",
            promptModeArgs: [], bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: true, isEnabled: true, builtinLogoAssetName: nil
        )
        let home = NSString(string: "~").expandingTildeInPath
        #expect(a.resolvedBinary == "\(home)/bin/x-bin")
    }

    @Test func resolvedBinaryExpandsTildeInBinary() {
        let a = AgentDefinition(
            id: "x", displayName: "X", binary: "~/bin/x-bin",
            binaryOverride: nil,
            promptModeArgs: [], bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
        let home = NSString(string: "~").expandingTildeInPath
        #expect(a.resolvedBinary == "\(home)/bin/x-bin")
    }

    @Test func extraTerminalArgsDefaultsToNil() {
        let agent = AgentDefinition(
            id: "test", displayName: "Test", binary: "test",
            binaryOverride: nil, promptModeArgs: [],
            bypassPermissionsFlag: nil, extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true, builtinLogoAssetName: nil
        )
        #expect(agent.extraTerminalArgs == nil)
    }

    @Test func resolvedBinaryLeavesBareNameAlone() {
        // No tilde, no path component → expandingTildeInPath is a no-op
        // and PATH lookup still works downstream.
        let a = AgentDefinition(
            id: "x", displayName: "X", binary: "claude",
            binaryOverride: nil,
            promptModeArgs: [], bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: true, isEnabled: true, builtinLogoAssetName: nil
        )
        #expect(a.resolvedBinary == "claude")
    }
}
