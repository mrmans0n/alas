import Foundation
import Testing
@testable import Alas

@Suite("Repo config decoding")
struct RepoConfigTests {
    private func decode(_ json: String) -> RepoConfig? {
        RepoConfig(jsonData: Data(json.utf8))
    }

    @Test func decodesFullConfig() throws {
        let config = try #require(decode("""
        {
          "version": 1,
          "icon": { "image": "logo.png" },
          "defaultAgent": "pi",
          "mcpServers": [
            { "name": "linear", "transport": { "kind": "http", "url": "https://mcp.linear.app/mcp", "headers": [] } },
            { "name": "db", "transport": { "kind": "stdio", "command": "npx", "args": ["-y", "db-mcp"], "environment": [] } }
          ]
        }
        """))
        #expect(config.icon?.image == "logo.png")
        #expect(config.defaultAgent == "pi")
        #expect(config.mcpServers.map(\.name) == ["linear", "db"])
        #expect(config.mcpServers[0].id == "repo:linear")
        if case .http(let url, _) = config.mcpServers[0].transport {
            #expect(url == "https://mcp.linear.app/mcp")
        } else {
            Issue.record("expected http transport")
        }
    }

    @Test func rejectsMissingAndWrongVersion() {
        #expect(decode(#"{"defaultAgent": "pi"}"#) == nil)
        #expect(decode(#"{"version": 2, "defaultAgent": "pi"}"#) == nil)
        #expect(decode("not json at all") == nil)
    }

    @Test func ignoresUnknownKeys() throws {
        let config = try #require(decode(#"{"version": 1, "futureThing": {"x": 1}, "defaultAgent": "pi"}"#))
        #expect(config.defaultAgent == "pi")
    }

    @Test func skipsMalformedServersAndBlankNames() throws {
        let config = try #require(decode("""
        {
          "version": 1,
          "mcpServers": [
            { "name": "good", "transport": { "kind": "stdio", "command": "npx", "args": [], "environment": [] } },
            { "name": "   ", "transport": { "kind": "stdio", "command": "npx", "args": [], "environment": [] } },
            { "name": "broken", "transport": { "kind": "carrier-pigeon" } },
            { "name": "good", "transport": { "kind": "stdio", "command": "other", "args": [], "environment": [] } }
          ]
        }
        """))
        #expect(config.mcpServers.map(\.name) == ["good"])
    }

    @Test func blankDefaultAgentBecomesNil() throws {
        let config = try #require(decode(#"{"version": 1, "defaultAgent": "  "}"#))
        #expect(config.defaultAgent == nil)
    }

    @Test func emptyFileDecodesToEmptyConfig() throws {
        #expect(try #require(decode(#"{"version": 1}"#)).isEmpty)
    }
}
