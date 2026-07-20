import Foundation
import Testing
@testable import Alas

private struct FixedVersionGGRunner: GGCommandRunning {
    let version: String?
    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        guard args == ["--version"], let version else {
            return ProcessResult(exitCode: 127, stdout: "", stderr: "not found")
        }
        return ProcessResult(exitCode: 0, stdout: "gg \(version)\n", stderr: "")
    }
}

@MainActor
struct GGAvailabilityTests {
    @Test func probePopulatesVersionAndMCPPath() async {
        let availability = GGAvailability()
        await availability.probe(
            service: GGService(runner: FixedVersionGGRunner(version: "0.9.9")),
            which: { name in name == "gg-mcp" ? "/opt/homebrew/bin/gg-mcp" : nil },
            force: true
        )
        #expect(availability.version == "0.9.9")
        #expect(availability.isInstalled)
        #expect(availability.ggMCPBinaryPath == "/opt/homebrew/bin/gg-mcp")
    }

    @Test func missingMCPBinaryYieldsNilWithoutAffectingGG() async {
        let availability = GGAvailability()
        await availability.probe(
            service: GGService(runner: FixedVersionGGRunner(version: "0.9.9")),
            which: { _ in nil },
            force: true
        )
        #expect(availability.isInstalled)
        #expect(availability.ggMCPBinaryPath == nil)
    }

    @Test func nonForceProbeIsCachedAfterFirstRun() async {
        let availability = GGAvailability()
        await availability.probe(
            service: GGService(runner: FixedVersionGGRunner(version: "1.0.0")),
            which: { _ in "/first/gg-mcp" },
            force: true
        )
        // Second, non-force probe must not overwrite cached results.
        await availability.probe(
            service: GGService(runner: FixedVersionGGRunner(version: "9.9.9")),
            which: { _ in "/second/gg-mcp" },
            force: false
        )
        #expect(availability.version == "1.0.0")
        #expect(availability.ggMCPBinaryPath == "/first/gg-mcp")
    }
}
