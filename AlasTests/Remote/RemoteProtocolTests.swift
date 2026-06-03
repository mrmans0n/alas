import Testing
import Foundation
@testable import Alas

struct RemoteProtocolTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test func clientMessageDecodesSubscribe() throws {
        let json = #"{"type":"subscribe","sessionId":"s1"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(RemoteClientMessage.self, from: json)
        #expect(msg == .subscribe(sessionId: "s1"))
    }

    @Test func clientMessageDecodesPermissionDecision() throws {
        let json = #"{"type":"permissionDecision","sessionId":"s1","requestId":7,"optionId":"allow_once","persistScope":"session"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(RemoteClientMessage.self, from: json)
        #expect(msg == .permissionDecision(sessionId: "s1", requestId: 7, optionId: "allow_once", persistScope: "session"))
    }

    @Test func clientMessageDecodesMissingPersistScope() throws {
        let json = #"{"type":"permissionDecision","sessionId":"s1","requestId":3,"optionId":"reject_once"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(RemoteClientMessage.self, from: json)
        #expect(msg == .permissionDecision(sessionId: "s1", requestId: 3, optionId: "reject_once", persistScope: nil))
    }

    @Test func clientMessageThrowsOnUnknownType() {
        let json = #"{"type":"bogus"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RemoteClientMessage.self, from: json)
        }
    }

    @Test func serverMessageThrowsOnUnknownType() {
        let json = #"{"type":"bogus"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RemoteServerMessage.self, from: json)
        }
    }

    @Test func serverMessageSnapshotRoundTrips() throws {
        let snap = RemoteServerMessage.transcriptSnapshot(
            sessionId: "s1",
            streamingState: "streaming",
            messages: [RemoteWireMessage(stableId: "m0", kind: "agent", text: "hi", json: nil)]
        )
        #expect(try roundTrip(snap) == snap)
    }

    @Test func sessionListRoundTrips() throws {
        let list = RemoteServerMessage.sessionList(sessions: [
            RemoteSessionSummary(id: "s1", title: "Build feature", agentId: "claude", status: "streaming")
        ])
        #expect(try roundTrip(list) == list)
    }

    @Test func transcriptDeltaRoundTrips() throws {
        let delta = RemoteServerMessage.transcriptDelta(
            sessionId: "s1",
            streamingState: "idle",
            upserts: [RemoteWireMessage(stableId: "m1", kind: "toolCall", text: nil, json: #"{"name":"bash"}"#)]
        )
        #expect(try roundTrip(delta) == delta)
    }

    @Test func permissionRequestRoundTrips() throws {
        let req = RemoteServerMessage.permissionRequest(
            sessionId: "s1",
            payload: RemotePermissionPayload(
                requestId: 9,
                toolName: "bash",
                options: [
                    RemotePermissionOption(optionId: "allow_once", name: "Allow", kind: "allow_once"),
                    RemotePermissionOption(optionId: "reject_once", name: "Deny", kind: "reject_once")
                ]))
        #expect(try roundTrip(req) == req)
    }

    @Test func permissionResolvedRoundTrips() throws {
        let resolved = RemoteServerMessage.permissionResolved(sessionId: "s1", requestId: 9)
        #expect(try roundTrip(resolved) == resolved)
    }
}
