import Testing
import Foundation
@testable import Alas

struct AgentDetectorTests {
    private func makeShim(in dir: URL, named: String) throws {
        let url = dir.appendingPathComponent(named)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func tmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-det-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func detectsBuiltinsOnPath() async throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeShim(in: dir, named: "claude")
        try makeShim(in: dir, named: "gemini")
        let installed = await AgentDetector.scan(
            path: dir.path,
            agents: AgentBuiltins.catalog
        )
        #expect(installed == Set(["claude", "gemini"]))
    }

    @Test func emptyPathYieldsNothing() async throws {
        let installed = await AgentDetector.scan(
            path: "",
            agents: AgentBuiltins.catalog
        )
        #expect(installed.isEmpty)
    }

    @Test func binaryOverrideHonoured() async throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeShim(in: dir, named: "claude")  // override target
        var claude = AgentBuiltins.entry(id: "claude")!
        claude.binaryOverride = dir.appendingPathComponent("claude").path
        let installed = await AgentDetector.scan(
            path: "",  // empty path; only the override should let claude pass
            agents: [claude]
        )
        #expect(installed == Set(["claude"]))
    }

    @Test func binaryOverrideToMissingFileNotDetected() async throws {
        var claude = AgentBuiltins.entry(id: "claude")!
        claude.binaryOverride = "/nonexistent/path/claude"
        let installed = await AgentDetector.scan(
            path: "/usr/bin:/bin",
            agents: [claude]
        )
        #expect(installed.isEmpty)
    }

    @Test func customAgentDetectedByBinaryOnPath() async throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeShim(in: dir, named: "myagent")
        let custom = AgentDefinition(
            id: "uuid-1", displayName: "Mine", binary: "myagent",
            binaryOverride: nil, promptModeArgs: [], bypassPermissionsFlag: nil,
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
        let installed = await AgentDetector.scan(
            path: dir.path,
            agents: [custom]
        )
        #expect(installed == Set(["uuid-1"]))
    }

    @Test func customAgentDetectedByAbsolutePathBinary() async throws {
        // Users can type an absolute path into the custom-agent binary
        // field directly. Detection must resolve it the same way it would
        // a builtin's binaryOverride, NOT try to PATH-scan it.
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeShim(in: dir, named: "myagent")
        let absolutePath = dir.appendingPathComponent("myagent").path
        let custom = AgentDefinition(
            id: "uuid-abs", displayName: "Abs",
            binary: absolutePath,
            binaryOverride: nil, promptModeArgs: [], bypassPermissionsFlag: nil,
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
        let installed = await AgentDetector.scan(
            path: "",  // empty PATH; absolute binary must still resolve
            agents: [custom]
        )
        #expect(installed == Set(["uuid-abs"]))
    }

    @Test func customAgentDetectedByTildePathBinary() async throws {
        // ~/-style paths in the custom binary field must be expanded
        // before the executable check.
        let home = NSString(string: "~").expandingTildeInPath
        let relative = "alas-det-tilde-\(UUID().uuidString)"
        let dir = URL(fileURLWithPath: home).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeShim(in: dir, named: "myagent")
        let custom = AgentDefinition(
            id: "uuid-tilde", displayName: "Tilde",
            binary: "~/\(relative)/myagent",
            binaryOverride: nil, promptModeArgs: [], bypassPermissionsFlag: nil,
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
        let installed = await AgentDetector.scan(
            path: "",
            agents: [custom]
        )
        #expect(installed == Set(["uuid-tilde"]))
    }
}
