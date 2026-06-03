// AlasTests/Remote/RemoteProtocolTests.swift
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
}
