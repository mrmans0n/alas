import Testing
import Foundation
@testable import Alas

@Suite struct ACPIncrementalReadTests {
    @Test("afterSeq returns appended and re-reads the boundary row")
    func incremental() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("incr-\(UUID()).sqlite")
        let writer = try ACPSessionStore(path: url.path)
        let now = Int64(Date().timeIntervalSince1970)
        try writer.upsertSession(ACPSessionRow(
            id: "s1", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: now, updatedAt: now, lastOpenedAt: now, archived: false))
        try writer.appendMessage(sessionId: "s1", id: "m0", kind: "text", seq: 0, payload: Data("a".utf8), createdAt: now)
        try writer.appendMessage(sessionId: "s1", id: "m1", kind: "text", seq: 1, payload: Data("b".utf8), createdAt: now)

        let mirror = try ACPSessionStore(path: url.path)
        // Mirror has seen up to seq 0; ask from seq 0 inclusive (boundary re-read).
        let fresh = try mirror.loadMessages(sessionId: "s1", afterSeq: 0)
        #expect(fresh.map { $0.seq } == [0, 1])

        // Writer mutates the streaming tail in place; mirror re-reads it.
        try writer.updateMessagePayload(id: "m1", payload: Data("b-more".utf8))
        let updated = try mirror.loadMessages(sessionId: "s1", afterSeq: 1)
        #expect(updated.first(where: { $0.seq == 1 })?.payload == Data("b-more".utf8))
    }
}
