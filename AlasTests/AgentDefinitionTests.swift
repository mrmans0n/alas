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
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
        #expect(a.resolvedBinary == "x-bin")
    }
}
