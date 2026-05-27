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
}
