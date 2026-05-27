import Foundation
import Testing
@testable import Alas

@Suite("ACPMessage")
struct ACPMessageTests {
    @Test("user message round-trips through JSON")
    func userRoundtrip() throws {
        let m = ACPMessage.user(text: "hello", attachments: [.init(uri: "file:///a.swift", name: "a.swift")])
        let payload = try ACPMessageCodec.encode(m)
        let back = try ACPMessageCodec.decode(kind: m.kind, payload: payload)
        #expect(back == m)
    }
    @Test("agent message round-trips")
    func agentRoundtrip() throws {
        let m = ACPMessage.agent(text: "world")
        let payload = try ACPMessageCodec.encode(m)
        let back = try ACPMessageCodec.decode(kind: m.kind, payload: payload)
        #expect(back == m)
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
        let m = ACPMessage.fileEdit(.init(path: "x.swift", added: 4, removed: 1))
        let payload = try ACPMessageCodec.encode(m)
        let back = try ACPMessageCodec.decode(kind: m.kind, payload: payload)
        #expect(back == m)
    }
}
