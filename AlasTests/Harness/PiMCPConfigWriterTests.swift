import Foundation
import Testing
@testable import Alas

@Suite("PiMCPConfigWriter")
struct PiMCPConfigWriterTests {
    private func makeWorktree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var servers: [ProjectMCPServer] {
        [ProjectMCPServer(
            id: "1", name: "linear",
            transport: .stdio(command: "/usr/bin/linear-mcp", args: ["--x"],
                              environment: [MCPKeyValue(id: "k", name: "TOKEN", value: "t0k")]))]
    }

    @Test("writes a managed config with 0600 and standard mcpServers shape")
    func writes() throws {
        let wt = try makeWorktree()
        let outcome = try PiMCPConfigWriter.sync(worktreeURL: wt, servers: servers, fingerprint: "fp1")
        #expect(outcome == .wrote)
        let url = wt.appendingPathComponent(".pi/mcp.json")
        let data = try Data(contentsOf: url)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let alas = try #require(json["$alas"] as? [String: Any])
        #expect(alas["managed"] as? Bool == true)
        #expect(alas["fingerprint"] as? String == "fp1")
        let mcp = try #require(json["mcpServers"] as? [String: Any])
        let linear = try #require(mcp["linear"] as? [String: Any])
        #expect(linear["command"] as? String == "/usr/bin/linear-mcp")
        #expect(linear["args"] as? [String] == ["--x"])
        #expect((linear["env"] as? [String: String])?["TOKEN"] == "t0k")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
        // no alas server ever written
        #expect(mcp["alas"] == nil)
    }

    @Test("same fingerprint is a no-op; new fingerprint rewrites")
    func fingerprintFreshness() throws {
        let wt = try makeWorktree()
        _ = try PiMCPConfigWriter.sync(worktreeURL: wt, servers: servers, fingerprint: "fp1")
        #expect(try PiMCPConfigWriter.sync(worktreeURL: wt, servers: servers, fingerprint: "fp1") == .unchanged)
        #expect(try PiMCPConfigWriter.sync(worktreeURL: wt, servers: servers, fingerprint: "fp2") == .wrote)
    }

    @Test("refuses to touch an unmanaged file")
    func refusesUnmanaged() throws {
        let wt = try makeWorktree()
        let dir = wt.appendingPathComponent(".pi", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"mcpServers": {"mine": {"command": "x"}}}"#
            .write(to: dir.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        #expect(try PiMCPConfigWriter.sync(worktreeURL: wt, servers: servers, fingerprint: "fp") == .refusedUnmanaged)
        let contents = try String(contentsOf: dir.appendingPathComponent("mcp.json"), encoding: .utf8)
        #expect(contents.contains("mine"))
    }

    @Test("removes a managed file when no servers remain")
    func removesManaged() throws {
        let wt = try makeWorktree()
        _ = try PiMCPConfigWriter.sync(worktreeURL: wt, servers: servers, fingerprint: "fp")
        #expect(try PiMCPConfigWriter.sync(worktreeURL: wt, servers: [], fingerprint: "fp0") == .removedManaged)
        #expect(!FileManager.default.fileExists(atPath: wt.appendingPathComponent(".pi/mcp.json").path))
        // and a fresh worktree with no servers is a clean no-op
        let wt2 = try makeWorktree()
        #expect(try PiMCPConfigWriter.sync(worktreeURL: wt2, servers: [], fingerprint: "fp0") == .noServers)
    }

    @Test("http and sse servers map to url and headers")
    func httpShape() throws {
        let wt = try makeWorktree()
        let http = [ProjectMCPServer(id: "2", name: "docs",
            transport: .http(url: "https://x/mcp",
                             headers: [MCPKeyValue(id: "h", name: "Authorization", value: "Bearer z")]))]
        _ = try PiMCPConfigWriter.sync(worktreeURL: wt, servers: http, fingerprint: "fp")
        let json = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: wt.appendingPathComponent(".pi/mcp.json"))) as? [String: Any])
        let docs = try #require((json["mcpServers"] as? [String: Any])?["docs"] as? [String: Any])
        #expect(docs["url"] as? String == "https://x/mcp")
        #expect((docs["headers"] as? [String: String])?["Authorization"] == "Bearer z")
    }
}
