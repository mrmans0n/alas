import Foundation
import Testing
@testable import Alas

@Suite("ACP MCP servers")
struct ACPMCPServerTests {
    @Test("encodes stdio servers without a type and with empty collections")
    func encodeStdio() throws {
        let json = try encodedObject(.stdio(
            name: "filesystem",
            command: "npx",
            args: [],
            env: []
        ))

        #expect(json["type"] == nil)
        #expect(json["name"] as? String == "filesystem")
        #expect(json["command"] as? String == "npx")
        #expect(json["args"] as? [String] == [])
        #expect(json["env"] as? [[String: String]] == [])
    }

    @Test("encodes HTTP servers with a type and empty headers")
    func encodeHTTP() throws {
        let json = try encodedObject(.http(
            name: "remote",
            url: "https://example.com/mcp",
            headers: []
        ))

        #expect(json["type"] as? String == "http")
        #expect(json["name"] as? String == "remote")
        #expect(json["url"] as? String == "https://example.com/mcp")
        #expect(json["headers"] as? [[String: String]] == [])
    }

    @Test("encodes SSE servers with a type and headers")
    func encodeSSE() throws {
        let json = try encodedObject(.sse(
            name: "events",
            url: "https://example.com/sse",
            headers: [.init(name: "Authorization", value: "Bearer token")]
        ))

        #expect(json["type"] as? String == "sse")
        #expect(json["name"] as? String == "events")
        #expect(json["url"] as? String == "https://example.com/sse")
        #expect(json["headers"] as? [[String: String]] == [[
            "name": "Authorization",
            "value": "Bearer token",
        ]])
    }

    @Test("decodes omitted server collections as empty")
    func decodeMissingCollections() throws {
        let stdio = try JSONDecoder().decode(ACPMCPServer.self, from: Data("""
        { "name": "filesystem", "command": "npx" }
        """.utf8))
        let http = try JSONDecoder().decode(ACPMCPServer.self, from: Data("""
        { "type": "http", "name": "remote", "url": "https://example.com/mcp" }
        """.utf8))
        let sse = try JSONDecoder().decode(ACPMCPServer.self, from: Data("""
        { "type": "sse", "name": "events", "url": "https://example.com/sse" }
        """.utf8))

        #expect(stdio == .stdio(name: "filesystem", command: "npx", args: [], env: []))
        #expect(http == .http(name: "remote", url: "https://example.com/mcp", headers: []))
        #expect(sse == .sse(name: "events", url: "https://example.com/sse", headers: []))
    }

    @Test("rejects unknown MCP server types")
    func decodeUnknownType() {
        let data = Data("""
        { "type": "websocket", "name": "remote", "url": "wss://example.com/mcp" }
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ACPMCPServer.self, from: data)
        }
    }

    @Test("decodes MCP transport capabilities with false defaults")
    func decodeCapabilities() throws {
        let httpOnly = try JSONDecoder().decode(ACPMCPServerCapabilities.self, from: Data("""
        { "http": true }
        """.utf8))
        let omitted = try JSONDecoder().decode(ACPMCPServerCapabilities.self, from: Data("{}".utf8))

        #expect(httpOnly.http == true)
        #expect(httpOnly.sse == false)
        #expect(omitted.http == false)
        #expect(omitted.sse == false)
    }

    private func encodedObject(_ server: ACPMCPServer) throws -> [String: Any] {
        let data = try JSONEncoder().encode(server)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
