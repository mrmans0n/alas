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
        let mcpServers: [ACPMCPServer] = [.stdio(name: "files", command: "mcp-files", args: ["--root", "/tmp"], env: [])]
        let new = try await conn.newSession(cwd: "/tmp", mcpServers: mcpServers)
        #expect(new.sessionId == "s1")
        #expect(new.availableModels.count == 1)
        #expect(new.availableModes.first?.id == "agent")
        let params = try #require(mock.sent.last?.params as? ACPSessionNewParams)
        #expect(params.mcpServers == mcpServers)
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
                },
                "mcpCapabilities": {
                  "http": true,
                  "sse": true
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
        #expect(initialized.mcpCapabilities == .init(http: true, sse: true))
    }

    @Test("initialize can suppress terminal capability")
    func initializeSuppressesTerminalCapability() async throws {
        let mock = ACPMockClient()
        mock.advertisesTerminalCapability = false
        mock.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }

        let conn = ACPConnection(client: mock)
        try await conn.initialize()

        let params = try #require(mock.sent.first?.params as? ACPInitializeParams)
        #expect(params.clientCapabilities.terminal == false)
    }

    @Test("startup methods carry broker operation keys")
    func startupMethodsCarryBrokerOperationKeys() async throws {
        let mock = ACPMockClient()
        mock.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
        mock.script(method: "session/new") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-new",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        mock.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-loaded",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        mock.script(method: "session/resume") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-resumed",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }

        let conn = ACPConnection(client: mock)
        try await conn.initialize(brokerOperationKey: "startup:init")
        _ = try await conn.newSession(cwd: "/tmp", mcpServers: [], brokerOperationKey: "startup:new")
        _ = try await conn.loadSession(
            cwd: "/tmp",
            sessionId: "remote-1",
            mcpServers: [],
            brokerOperationKey: "startup:load"
        )
        _ = try await conn.resumeSession(
            cwd: "/tmp",
            sessionId: "remote-1",
            mcpServers: [],
            brokerOperationKey: "startup:resume"
        )

        #expect(mock.sent.map(\.brokerOperationKey) == [
            "startup:init",
            "startup:new",
            "startup:load",
            "startup:resume"
        ])
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
        let mcpServers: [ACPMCPServer] = [.http(name: "remote", url: "https://mcp.example.com", headers: [])]
        let result = try await conn.loadSession(cwd: "/tmp/wt", sessionId: "remote-old", mcpServers: mcpServers)

        #expect(result.sessionId == "remote-restored")
        let req = try #require(mock.sent.last)
        #expect(req.method == "session/load")
        let params = try #require(req.params as? ACPSessionLoadParams)
        #expect(params.cwd == "/tmp/wt")
        #expect(params.sessionId == "remote-old")
        #expect(params.mcpServers == mcpServers)
    }

    @Test("resumeSession sends session/resume and preserves the requested id for an empty result")
    func resumeSessionRPC() async throws {
        let mock = ACPMockClient()
        mock.script(method: "session/resume") { _ in Data("{}".utf8) }

        let conn = ACPConnection(client: mock)
        let mcpServers: [ACPMCPServer] = [.sse(name: "events", url: "https://mcp.example.com/events", headers: [])]
        let result = try await conn.resumeSession(cwd: "/tmp/wt", sessionId: "remote-old", mcpServers: mcpServers)

        #expect(result.sessionId == "remote-old")
        let req = try #require(mock.sent.last)
        #expect(req.method == "session/resume")
        let params = try #require(req.params as? ACPSessionResumeParams)
        #expect(params.cwd == "/tmp/wt")
        #expect(params.sessionId == "remote-old")
        #expect(params.mcpServers == mcpServers)
    }

    @Test("forkSession carries broker key and defers durable acknowledgement")
    func forkSessionDurableRPC() async throws {
        let mock = ACPMockClient()
        let acknowledgement = DurableAcknowledgementRecorder()
        mock.scriptResponse(method: "session/fork") { _ in
            ACPResponse(
                body: try JSONEncoder().encode(ACPSessionNewResult(
                    sessionId: "forked",
                    availableModels: [],
                    availableModes: [],
                    currentModel: nil,
                    currentMode: nil,
                    promptSuggestions: []
                )),
                durableConsumptionAcknowledgement: { acknowledgement.record() }
            )
        }
        let connection = ACPConnection(client: mock)

        let result = try await connection.forkSession(
            cwd: "/tmp/wt",
            sessionId: "source-remote",
            mcpServers: [],
            brokerOperationKey: "startup:target:session/fork:source-remote"
        )

        #expect(result.sessionId == "forked")
        #expect(mock.sent.last?.brokerOperationKey == "startup:target:session/fork:source-remote")
        #expect(acknowledgement.count == 0)
        connection.acknowledgeDurableSessionResponses()
        #expect(acknowledgement.count == 1)
    }

    @Test("forkSession rejects an empty session id without consuming its durable response")
    func forkSessionRejectsEmptySessionID() async throws {
        let mock = ACPMockClient()
        let acknowledgement = DurableAcknowledgementRecorder()
        mock.scriptResponse(method: "session/fork") { _ in
            ACPResponse(
                body: try JSONEncoder().encode(ACPSessionNewResult(
                    sessionId: "",
                    availableModels: [],
                    availableModes: [],
                    currentModel: nil,
                    currentMode: nil,
                    promptSuggestions: []
                )),
                durableConsumptionAcknowledgement: { acknowledgement.record() }
            )
        }
        let connection = ACPConnection(client: mock)

        do {
            _ = try await connection.forkSession(
                cwd: "/tmp/wt",
                sessionId: "source-remote",
                mcpServers: []
            )
            Issue.record("Expected an empty fork session id to be rejected")
        } catch is DecodingError {
            // Expected.
        }

        #expect(acknowledgement.count == 0)
        connection.acknowledgeDurableSessionResponses()
        #expect(acknowledgement.count == 1)
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

private final class DurableAcknowledgementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
