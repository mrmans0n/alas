import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPMessage")
struct ACPMessageTests {
    @Test("user message round-trips through JSON")
    func userRoundtrip() throws {
        let m = ACPMessage.user(id: UUID(), text: "hello", attachments: [.init(uri: "file:///a.swift", name: "a.swift")])
        let payload = try ACPMessageCodec.encode(m)
        let back = try ACPMessageCodec.decode(kind: m.kind, payload: payload)
        guard case .user(_, let text, let atts) = back else {
            Issue.record("expected user message")
            return
        }
        #expect(text == "hello")
        #expect(atts.count == 1)
        #expect(atts[0].uri == "file:///a.swift")
    }
    @Test("agent message round-trips")
    func agentRoundtrip() throws {
        let m = ACPMessage.agent(id: UUID(), StreamingText("world"))
        let payload = try ACPMessageCodec.encode(m)
        let back = try ACPMessageCodec.decode(kind: m.kind, payload: payload)
        guard case .agent(_, let buf) = back else {
            Issue.record("expected agent message")
            return
        }
        #expect(buf.value == "world")
    }
    @Test("tool call round-trips")
    func toolRoundtrip() throws {
        let m = ACPMessage.toolCall(.init(
            toolCallId: "tc-1", title: "read_file", kind: "read",
            status: "completed", content: "8.2k bytes", preview: "8.2k",
            locations: ["file://x"]))
        let payload = try ACPMessageCodec.encode(m)
        let back = try ACPMessageCodec.decode(kind: m.kind, payload: payload)
        #expect(back == m)
    }
    @Test("file edit round-trips")
    func editRoundtrip() throws {
        let m = ACPMessage.fileEdit(id: UUID(), .init(path: "x.swift", added: 4, removed: 1))
        let payload = try ACPMessageCodec.encode(m)
        let back = try ACPMessageCodec.decode(kind: m.kind, payload: payload)
        guard case .fileEdit(_, let edit) = back else {
            Issue.record("expected file edit")
            return
        }
        #expect(edit.path == "x.swift")
        #expect(edit.added == 4)
        #expect(edit.removed == 1)
    }
}
