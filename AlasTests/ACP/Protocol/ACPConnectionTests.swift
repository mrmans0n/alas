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

    @Test("setConfigOption sends session/set_config_option with sessionId, configId, value")
    func setConfigOptionRPC() async throws {
        let mock = ACPMockClient()
        mock.script(method: "session/set_config_option") { _ in
            Data()
        }

        let conn = ACPConnection(client: mock)
        _ = try await conn.setConfigOption(sessionId: "sess-1", configId: "effort", value: "high")

        let req = try #require(mock.sent.last)
        #expect(req.method == "session/set_config_option")

        let params = try #require(req.params as? ACPSessionSetConfigOptionParams)
        #expect(params.sessionId == "sess-1")
        #expect(params.configId == "effort")
        #expect(params.value == "high")
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
        let result = try await conn.setConfigOption(sessionId: "s", configId: "effort", value: "high")
        #expect(result.count == 1)
        #expect(result[0].currentValue == "high")
        #expect(result[0].options.count == 2)
    }

    @Test("setConfigOption returns empty when agent omits the echo")
    func setConfigOptionEmptyResponse() async throws {
        let mock = ACPMockClient()
        mock.script(method: "session/set_config_option") { _ in Data() }
        let conn = ACPConnection(client: mock)
        let result = try await conn.setConfigOption(sessionId: "s", configId: "effort", value: "high")
        #expect(result.isEmpty)
    }
}
