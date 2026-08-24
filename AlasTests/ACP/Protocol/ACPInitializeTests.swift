import Foundation
import Testing
@testable import Alas

@Suite("ACP initialize")
struct ACPInitializeTests {
    @Test("decodes an initialize request")
    func decodeRequest() throws {
        let data = try fixture("initialize-request")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPInitializeParams>.self, from: data)
        #expect(env.id == .number(1))
        #expect(env.method == "initialize")
        #expect(env.params?.protocolVersion == 1)
        #expect(env.params?.clientCapabilities.fs.readTextFile == true)
        #expect(env.params?.clientCapabilities.fs.writeTextFile == true)
        #expect(env.params?.clientCapabilities.terminal == true)
    }

    @Test("decoding legacy initialize request does not imply terminal auth")
    func decodeLegacyRequestWithoutAuthCapability() throws {
        let data = Data("""
        {
          "jsonrpc": "2.0",
          "id": 1,
          "method": "initialize",
          "params": {
            "protocolVersion": 1,
            "clientCapabilities": {
              "fs": { "readTextFile": true, "writeTextFile": true },
              "terminal": true
            }
          }
        }
        """.utf8)

        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPInitializeParams>.self, from: data)

        #expect(env.params?.clientCapabilities.auth.terminal == false)
        #expect(env.params?.clientCapabilities.meta.terminalAuth == false)
    }

    @Test("decoding empty session capabilities does not imply boolean config support")
    func decodeEmptySessionCapabilities() throws {
        let data = Data("""
        {
          "jsonrpc": "2.0",
          "id": 1,
          "method": "initialize",
          "params": {
            "protocolVersion": 1,
            "clientCapabilities": {
              "fs": { "readTextFile": true, "writeTextFile": true },
              "terminal": true,
              "session": {}
            }
          }
        }
        """.utf8)

        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPInitializeParams>.self, from: data)

        #expect(env.params?.clientCapabilities.session.configOptions.boolean == nil)
    }

    @Test("decoding null configOptions does not imply boolean config support")
    func decodeNullSessionConfigOptions() throws {
        let data = Data("""
        {
          "jsonrpc": "2.0",
          "id": 1,
          "method": "initialize",
          "params": {
            "protocolVersion": 1,
            "clientCapabilities": {
              "fs": { "readTextFile": true, "writeTextFile": true },
              "terminal": true,
              "session": { "configOptions": null }
            }
          }
        }
        """.utf8)

        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPInitializeParams>.self, from: data)

        #expect(env.params?.clientCapabilities.session.configOptions.boolean == nil)
    }

    @Test("initialize request advertises terminal auth capabilities")
    func initializeRequestAdvertisesAuth() throws {
        let params = ACPInitializeParams(
            protocolVersion: 1,
            clientCapabilities: .init(
                fs: .init(readTextFile: true, writeTextFile: true),
                terminal: true
            )
        )
        let envelope = JSONRPCEnvelope<ACPInitializeParams>(
            id: .number(1),
            method: "initialize",
            params: params
        )

        let data = try JSONEncoder().encode(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedParams = try #require(json["params"] as? [String: Any])
        let capabilities = try #require(encodedParams["clientCapabilities"] as? [String: Any])
        let auth = try #require(capabilities["auth"] as? [String: Any])
        let meta = try #require(capabilities["_meta"] as? [String: Any])

        #expect(auth["terminal"] as? Bool == true)
        #expect(meta["terminal-auth"] as? Bool == true)
        #expect(meta["parameterizedModelPicker"] as? Bool == true)
        let session = try #require(capabilities["session"] as? [String: Any])
        let configOptions = try #require(session["configOptions"] as? [String: Any])
        #expect(configOptions["boolean"] as? [String: Any] != nil)
        #expect(capabilities["terminal"] as? Bool == true)
        let elicitation = try #require(capabilities["elicitation"] as? [String: Any])
        #expect(elicitation["form"] as? [String: Any] != nil)
        #expect(elicitation["url"] as? [String: Any] != nil)
        let fs = try #require(capabilities["fs"] as? [String: Any])
        #expect(fs["readTextFile"] as? Bool == true)
        #expect(fs["writeTextFile"] as? Bool == true)
    }

    @Test("decodes an initialize response")
    func decodeResponse() throws {
        let data = try fixture("initialize-response")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPInitializeResult>.self, from: data)
        #expect(env.result?.protocolVersion == 1)
        #expect(env.result?.authMethods.isEmpty == true)
    }

    @Test("decodes initialize response without authMethods")
    func decodeResponseWithoutAuthMethods() throws {
        let data = Data("""
        {
          "protocolVersion": 1,
          "agentCapabilities": {
            "promptCapabilities": {
              "embeddedContext": true
            }
          }
        }
        """.utf8)

        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: data)

        #expect(result.authMethods.isEmpty)
        #expect(result.agentCapabilities?.promptCapabilities?.embeddedContext == true)
    }

    @Test("decodes absent, supported, and extended provider capabilities")
    func decodeProviderCapabilities() throws {
        let absent = try JSONDecoder().decode(ACPInitializeResult.self, from: Data("""
        { "protocolVersion": 1, "agentCapabilities": {} }
        """.utf8))
        #expect(absent.agentCapabilities?.providerCapabilities == nil)

        let supported = try JSONDecoder().decode(ACPInitializeResult.self, from: Data("""
        {
          "protocolVersion": 1,
          "agentCapabilities": { "providers": {} }
        }
        """.utf8))
        #expect(supported.agentCapabilities?.providerCapabilities != nil)

        let extended = try JSONDecoder().decode(ACPInitializeResult.self, from: Data("""
        {
          "protocolVersion": 1,
          "agentCapabilities": {
            "providers": {
              "version": 2,
              "switchesLoadedSessions": true,
              "future": { "nested": [1, 2, 3] }
            }
          }
        }
        """.utf8))
        #expect(extended.agentCapabilities?.providerCapabilities != nil)
    }

    @Test("decodes agent session lifecycle capabilities with conservative defaults")
    func decodeSessionLifecycleCapabilities() throws {
        let supported = try JSONDecoder().decode(ACPInitializeResult.self, from: Data("""
        {
          "protocolVersion": 1,
          "agentCapabilities": {
            "loadSession": true,
            "sessionCapabilities": { "list": {}, "resume": {}, "fork": {} }
          }
        }
        """.utf8))

        #expect(supported.agentCapabilities?.loadSession == true)
        #expect(supported.agentCapabilities?.sessionCapabilities.supportsList == true)
        #expect(supported.agentCapabilities?.sessionCapabilities.supportsResume == true)
        #expect(supported.agentCapabilities?.sessionCapabilities.supportsFork == true)

        let omitted = try JSONDecoder().decode(ACPInitializeResult.self, from: Data("""
        { "protocolVersion": 1, "agentCapabilities": {} }
        """.utf8))
        #expect(omitted.agentCapabilities?.loadSession == false)
        #expect(omitted.agentCapabilities?.sessionCapabilities.supportsList == false)
        #expect(omitted.agentCapabilities?.sessionCapabilities.supportsResume == false)
        #expect(omitted.agentCapabilities?.sessionCapabilities.supportsFork == false)
    }

    @Test("decodes MCP transport capabilities with conservative defaults")
    func decodeMCPTransportCapabilities() throws {
        let supported = try JSONDecoder().decode(ACPInitializeResult.self, from: Data("""
        {
          "protocolVersion": 1,
          "agentCapabilities": {
            "mcpCapabilities": { "http": true, "sse": true }
          }
        }
        """.utf8))
        let missingObject = try JSONDecoder().decode(ACPInitializeResult.self, from: Data("""
        { "protocolVersion": 1, "agentCapabilities": {} }
        """.utf8))
        let missingFields = try JSONDecoder().decode(ACPInitializeResult.self, from: Data("""
        {
          "protocolVersion": 1,
          "agentCapabilities": { "mcpCapabilities": {} }
        }
        """.utf8))

        #expect(supported.agentCapabilities?.mcpCapabilities.http == true)
        #expect(supported.agentCapabilities?.mcpCapabilities.sse == true)
        #expect(missingObject.agentCapabilities?.mcpCapabilities.http == false)
        #expect(missingObject.agentCapabilities?.mcpCapabilities.sse == false)
        #expect(missingFields.agentCapabilities?.mcpCapabilities.http == false)
        #expect(missingFields.agentCapabilities?.mcpCapabilities.sse == false)
    }

    @Test("decodes terminal auth method metadata")
    func decodesTerminalAuthMethod() throws {
        let data = Data("""
        {
          "protocolVersion": 1,
          "authMethods": [
            {
              "id": "claude-ai-login",
              "name": "Claude Subscription",
              "description": "Use Claude subscription",
              "type": "terminal",
              "args": ["--cli", "auth", "login"],
              "env": { "A": "B" },
              "vars": [
                { "name": "ANTHROPIC_API_KEY", "label": "API key", "optional": false, "secret": true }
              ],
              "_meta": {
                "terminal-auth": {
                  "command": "/usr/bin/node",
                  "args": ["/opt/claude-agent-acp", "--cli"],
                  "label": "Claude Login"
                }
              }
            }
          ]
        }
        """.utf8)

        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: data)
        let method = try #require(result.authMethods.first)
        #expect(method.id == "claude-ai-login")
        #expect(method.name == "Claude Subscription")
        #expect(method.description == "Use Claude subscription")
        #expect(method.kind == .terminal)
        #expect(method.args == ["--cli", "auth", "login"])
        #expect(method.env == ["A": "B"])
        #expect(method.vars?.first?.name == "ANTHROPIC_API_KEY")
        #expect(method.vars?.first?.label == "API key")
        #expect(method.vars?.first?.optional == false)
        #expect(method.vars?.first?.secret == true)
        #expect(method.terminalAuth?.command == "/usr/bin/node")
        #expect(method.terminalAuth?.args == ["/opt/claude-agent-acp", "--cli"])
        #expect(method.terminalAuth?.label == "Claude Login")
    }

    @Test("decodes auth method type variants")
    func decodesAuthMethodTypeVariants() throws {
        let data = Data("""
        {
          "protocolVersion": 1,
          "authMethods": [
            { "id": "agent-login", "name": "Agent Login" },
            { "id": "env-login", "name": "Environment", "type": "env_var" },
            { "id": "future-login", "name": "Future", "type": "browser" }
          ]
        }
        """.utf8)

        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: data)

        #expect(result.authMethods.map(\.kind) == [
            .agent,
            .envVar,
            .unknown("browser"),
        ])
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: ACPInitializeFixtureMarker.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}

private final class ACPInitializeFixtureMarker {}
