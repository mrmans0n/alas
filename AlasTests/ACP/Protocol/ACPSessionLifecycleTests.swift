import Foundation
import Testing
@testable import Alas

@Suite("ACP session lifecycle")
struct ACPSessionLifecycleTests {
    @Test("decodes session/new request")
    func decodeNew() throws {
        let data = try fixture("session-new-request")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPSessionNewParams>.self, from: data)
        #expect(env.method == "session/new")
        #expect(env.params?.cwd == "/Users/me/proj")
    }

    @Test("decodes session/new response with models/modes/suggestions")
    func decodeNewResponse() throws {
        let data = try fixture("session-new-response")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPSessionNewResult>.self, from: data)
        let r = try #require(env.result)
        #expect(r.sessionId == "sess-abc")
        #expect(r.availableModels.count == 1)
        #expect(r.availableModes.count == 2)
        #expect(r.currentModel == "sonnet")
        #expect(r.currentMode == "agent")
        #expect(r.promptSuggestions.first?.command == "/clear")
    }

    @Test("decodes session/new response with config options")
    func decodeConfigOptions() throws {
        let data = try fixture("session-new-response-with-config-options")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPSessionNewResult>.self, from: data)
        let r = try #require(env.result)
        #expect(r.configOptions.count == 1)
        #expect(r.configOptions[0].id == "effort")
        #expect(r.configOptions[0].currentValue == "medium")
        #expect(r.configOptions[0].options.count == 3)
    }

    @Test("session/new response without configOptions decodes with empty array")
    func decodeNoConfigOptions() throws {
        let data = try fixture("session-new-response")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPSessionNewResult>.self, from: data)
        let r = try #require(env.result)
        #expect(r.configOptions.isEmpty)
    }

    @Test("encodes session/cancel request")
    func encodeCancel() throws {
        let env = JSONRPCEnvelope(
            id: .number(3),
            method: "session/cancel",
            params: ACPSessionCancelParams(sessionId: "sess-abc")
        )
        let data = try JSONEncoder().encode(env)
        let back = try JSONDecoder().decode(JSONRPCEnvelope<ACPSessionCancelParams>.self, from: data)
        #expect(back.method == "session/cancel")
        #expect(back.params?.sessionId == "sess-abc")
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: ACPSessionLifecycleFixtureMarker.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}

private final class ACPSessionLifecycleFixtureMarker {}
