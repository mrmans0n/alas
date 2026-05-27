import Foundation
import Testing
@testable import Alas

@Suite("ACPMockClient")
struct ACPMockClientTests {
    @Test("scripted updates appear on incomingUpdates")
    func updatesAppear() async {
        let mock = ACPMockClient()
        let collected = Task {
            var out: [ACPSessionUpdate] = []
            for await u in mock.incomingUpdates { out.append(u.update); if out.count == 2 { break } }
            return out
        }
        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("hi "))))
        mock.emit(.init(sessionId: "s", update: .agentMessageChunk(.text("there"))))
        let got = await collected.value
        #expect(got.count == 2)
    }

    @Test("send returns the scripted response for a request method")
    func scriptedResponse() async throws {
        let mock = ACPMockClient()
        mock.script(method: "session/new") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "x", availableModels: [], availableModes: [],
                currentModel: nil, currentMode: nil, promptSuggestions: []
            ))
        }
        let req = ACPRequest(method: "session/new", params: ["cwd":"/tmp"])
        let resp = try await mock.send(req)
        let decoded = try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
        #expect(decoded.sessionId == "x")
    }
}
