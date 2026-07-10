import Foundation
import Testing
@testable import Alas

@Suite("ACPConnection")
struct ACPConnectionTests {
    @Test("initialize + new session populates sessionId, models, modes")
    func newSession() async throws {
        let mock = ACPMockClient()
        mock.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1, agentCapabilities: nil, authMethods: []))
        }
        mock.script(method: "session/new") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "s1",
                availableModels: [.init(id: "sonnet", name: "Sonnet")],
                availableModes: [.init(id: "agent", name: "Agent")],
                currentModel: "sonnet", currentMode: "agent",
                promptSuggestions: []))
        }

        let conn = ACPConnection(client: mock)
        try await conn.initialize()
        let new = try await conn.newSession(cwd: "/tmp")
        #expect(new.sessionId == "s1")
        #expect(new.availableModels.count == 1)
        #expect(new.availableModes.first?.id == "agent")
    }

    @Test("initialize returns prompt capabilities")
    func initializeReturnsPromptCapabilities() async throws {
        let mock = ACPMockClient()
        mock.script(method: "initialize") { _ in
            """
            {
              "protocolVersion": 1,
              "agentCapabilities": {
                "promptCapabilities": {
                  "image": true,
                  "audio": false,
                  "embeddedContext": true
                }
              },
              "authMethods": [
                { "id": "claude-ai-login", "name": "Claude Subscription", "type": "terminal" }
              ]
            }
            """.data(using: .utf8)!
        }

        let conn = ACPConnection(client: mock)
        let initialized = try await conn.initialize()

        #expect(initialized.promptCapabilities.image == true)
        #expect(initialized.promptCapabilities.audio == false)
        #expect(initialized.promptCapabilities.embeddedContext == true)
        #expect(initialized.authMethods.map(\.id) == ["claude-ai-login"])
    }

    @Test("loadSession sends session/load with cwd and remote session id")
    func loadSessionRPC() async throws {
        let mock = ACPMockClient()
        mock.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-restored",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }

        let conn = ACPConnection(client: mock)
        let result = try await conn.loadSession(cwd: "/tmp/wt", sessionId: "remote-old")

        #expect(result.sessionId == "remote-restored")
        let req = try #require(mock.sent.last)
        #expect(req.method == "session/load")
        let params = try #require(req.params as? ACPSessionLoadParams)
        #expect(params.cwd == "/tmp/wt")
        #expect(params.sessionId == "remote-old")
        #expect(params.mcpServers.isEmpty)
    }

    @Test("resumeSession sends session/resume and preserves the requested id for an empty result")
    func resumeSessionRPC() async throws {
        let mock = ACPMockClient()
        mock.script(method: "session/resume") { _ in Data("{}".utf8) }

        let conn = ACPConnection(client: mock)
        let result = try await conn.resumeSession(cwd: "/tmp/wt", sessionId: "remote-old")

        #expect(result.sessionId == "remote-old")
        let req = try #require(mock.sent.last)
        #expect(req.method == "session/resume")
        let params = try #require(req.params as? ACPSessionResumeParams)
        #expect(params.cwd == "/tmp/wt")
        #expect(params.sessionId == "remote-old")
    }

    @Test("listSessions sends cwd and opaque cursor and decodes a page")
    func listSessionsRPC() async throws {
        let mock = ACPMockClient()
        mock.script(method: "session/list") { _ in
            try JSONEncoder().encode(ACPSessionListResult(
                sessions: [.init(
                    sessionId: "remote-1",
                    cwd: "/tmp/wt",
                    title: "Fix tests",
                    updatedAt: "2026-07-10T10:00:00Z"
                )],
                nextCursor: "page-2"
            ))
        }

        let conn = ACPConnection(client: mock)
        let result = try await conn.listSessions(cwd: "/tmp/wt", cursor: "page-1")

        #expect(result.sessions.map(\.sessionId) == ["remote-1"])
        #expect(result.nextCursor == "page-2")
        let req = try #require(mock.sent.last)
        let params = try #require(req.params as? ACPSessionListParams)
        #expect(params.cwd == "/tmp/wt")
        #expect(params.cursor == "page-1")
    }

    @Test("authenticate sends method id")
    func authenticateRPC() async throws {
        let mock = ACPMockClient()
        mock.script(method: "authenticate") { _ in Data() }

        let conn = ACPConnection(client: mock)
        try await conn.authenticate(methodId: "claude-login")

        let req = try #require(mock.sent.last)
        #expect(req.method == "authenticate")
        let params = try #require(req.params as? ACPAuthenticateParams)
        #expect(params.methodId == "claude-login")
    }

    @Test("setConfigOption sends session/set_config_option with sessionId, configId, value")
    func setConfigOptionRPC() async throws {
        let mock = ACPMockClient()
        mock.script(method: "session/set_config_option") { _ in
            Data()
        }

        let conn = ACPConnection(client: mock)
        _ = try await conn.setConfigOption(sessionId: "sess-1", configId: "effort", value: .string("high"))

        let req = try #require(mock.sent.last)
        #expect(req.method == "session/set_config_option")

        let params = try #require(req.params as? ACPSessionSetConfigOptionParams)
        #expect(params.sessionId == "sess-1")
        #expect(params.configId == "effort")
        #expect(params.value == .string("high"))
    }

    @Test("setConfigOption returns refreshed configOptions from response")
    func setConfigOptionAppliesResponse() async throws {
        let mock = ACPMockClient()
        mock.script(method: "session/set_config_option") { _ in
            """
            {"configOptions":[
                {"id":"effort","name":"Effort","type":"select","currentValue":"high",
                 "options":[{"value":"low","name":"Low"},{"value":"high","name":"High"}]}
            ]}
            """.data(using: .utf8)!
        }

        let conn = ACPConnection(client: mock)
        let result = try await conn.setConfigOption(sessionId: "s", configId: "effort", value: .string("high"))
        #expect(result.count == 1)
        #expect(result[0].currentValue == .string("high"))
        #expect(result[0].options.count == 2)
    }

    @Test("setConfigOption returns empty when agent omits the echo")
    func setConfigOptionEmptyResponse() async throws {
        let mock = ACPMockClient()
        mock.script(method: "session/set_config_option") { _ in Data() }
        let conn = ACPConnection(client: mock)
        let result = try await conn.setConfigOption(sessionId: "s", configId: "effort", value: .string("high"))
        #expect(result.isEmpty)
    }
}
