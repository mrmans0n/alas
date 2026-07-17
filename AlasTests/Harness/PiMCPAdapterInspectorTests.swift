import Foundation
import Testing
@testable import Alas

@Suite("PiMCPAdapterInspector")
struct PiMCPAdapterInspectorTests {
    private func makeAgentDir(packageJSON: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-agent-\(UUID().uuidString)/npm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let packageJSON {
            try packageJSON.write(to: dir.appendingPathComponent("package.json"),
                                  atomically: true, encoding: .utf8)
        }
        return dir.deletingLastPathComponent()
    }

    @Test("installed when dependencies contain pi-mcp-adapter")
    func installed() throws {
        let dir = try makeAgentDir(packageJSON:
            #"{"dependencies": {"pi-mcp-adapter": "^2.11.0", "other": "1.0.0"}}"#)
        #expect(PiMCPAdapterInspector.state(agentDir: dir) == .installed)
    }

    @Test("missing when the manifest parses without it")
    func missing() throws {
        let dir = try makeAgentDir(packageJSON: #"{"dependencies": {"other": "1.0.0"}}"#)
        #expect(PiMCPAdapterInspector.state(agentDir: dir) == .missing)
    }

    @Test("unknown when manifest is absent or unreadable")
    func unknown() throws {
        let absent = try makeAgentDir(packageJSON: nil)
        #expect(PiMCPAdapterInspector.state(agentDir: absent) == .unknown)
        let garbled = try makeAgentDir(packageJSON: "not json")
        #expect(PiMCPAdapterInspector.state(agentDir: garbled) == .unknown)
    }
}
