import Foundation
import Testing
@testable import Alas

@Suite("ACPLaunchSpec.npmPackageName")
struct ACPLaunchSpecNpmPackageTests {
    @Test("binaryOnPathOrNpmPackage exposes the package name")
    func extractsFromCombinedCheck() {
        let spec = ACPLaunchSpec(
            agentID: "test-agent",
            command: "test-bin",
            arguments: [],
            extraEnv: [:],
            setupCheck: .binaryOnPathOrNpmPackage(
                binary: "test-bin",
                npmPackage: "test-pkg"),
            supportsModelSelection: true,
            supportsModeSelection: true)
        #expect(spec.npmPackageName == "test-pkg")
    }

    @Test("npxPackage exposes the package name")
    func extractsFromNpxPackage() {
        let spec = ACPLaunchSpec(
            agentID: "x",
            command: "x",
            arguments: [],
            extraEnv: [:],
            setupCheck: .npxPackage(name: "some-pkg"),
            supportsModelSelection: false,
            supportsModeSelection: false)
        #expect(spec.npmPackageName == "some-pkg")
    }

    @Test("binaryOnPath has no npm package")
    func binaryOnlyHasNone() {
        let spec = ACPLaunchSpec(
            agentID: "test-binary",
            command: "test-bin",
            arguments: [],
            extraEnv: [:],
            setupCheck: .binaryOnPath(name: "test-bin"),
            supportsModelSelection: true,
            supportsModeSelection: false)
        #expect(spec.npmPackageName == nil)
    }

    @Test("claude, codex, pi all expose their npm packages via the catalog")
    func catalogCoverage() {
        let byID = Dictionary(uniqueKeysWithValues: ACPLaunchCatalog.specs.map { ($0.agentID, $0) })
        #expect(byID["claude"]?.npmPackageName == "@agentclientprotocol/claude-agent-acp")
        #expect(byID["codex"]?.npmPackageName == "@zed-industries/codex-acp")
        #expect(byID["pi"]?.npmPackageName == "pi-acp")
    }
}
