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
        // first entry wins, not just for the name list but for the definition
        if case .stdio(let command, _, _) = try #require(config.mcpServers.first).transport {
            #expect(command == "npx")
        } else {
            Issue.record("expected stdio transport")
        }
    }

    @Test func serverNamesAreTrimmed() throws {
        let config = try #require(decode("""
        {
          "version": 1,
          "mcpServers": [
            { "name": "  good  ", "transport": { "kind": "stdio", "command": "npx", "args": [], "environment": [] } }
          ]
        }
        """))
        #expect(config.mcpServers.map(\.name) == ["good"])
        #expect(config.mcpServers.first?.id == "repo:good")
    }

    @Test func blankDefaultAgentBecomesNil() throws {
        let config = try #require(decode(#"{"version": 1, "defaultAgent": "  "}"#))
        #expect(config.defaultAgent == nil)
    }

    @Test func blankIconImageBecomesNil() throws {
        let config = try #require(decode(#"{"version": 1, "icon": {"image": "   "}}"#))
        #expect(config.icon == nil)
    }

    @Test func wrongTypeForIconKeepsOtherKeys() throws {
        let config = try #require(decode(#"{"version": 1, "icon": "logo.png", "defaultAgent": "pi"}"#))
        #expect(config.icon == nil)
        #expect(config.defaultAgent == "pi")
    }

    @Test func wrongTypeForServersKeepsOtherKeys() throws {
        let config = try #require(decode(#"{"version": 1, "mcpServers": {}, "defaultAgent": "pi"}"#))
        #expect(config.mcpServers.isEmpty)
        #expect(config.defaultAgent == "pi")
    }

    @Test func iconPathsCannotEscapeTheCheckout() throws {
        let traversing = try #require(decode(#"{"version": 1, "icon": {"image": "../../outside.png"}}"#))
        #expect(traversing.icon == nil)

        let absolute = try #require(decode(#"{"version": 1, "icon": {"image": "/tmp/outside.png"}}"#))
        #expect(absolute.icon == nil)

        let nested = try #require(decode(#"{"version": 1, "icon": {"image": "brand/logo.png"}}"#))
        #expect(nested.icon?.image == "brand/logo.png")
    }

    @Test func emptyFileDecodesToEmptyConfig() throws {
        #expect(try #require(decode(#"{"version": 1}"#)).isEmpty)
    }
}
