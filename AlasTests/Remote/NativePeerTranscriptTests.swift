import Testing
@testable import Alas

@MainActor
struct NativePeerTranscriptTests {
    private func row(_ id: String, index: Int, text: String) -> RemoteWireMessage {
        RemoteWireMessage(stableId: id, kind: "agent", text: text, json: nil, index: index)
    }

    @Test func snapshotsAndContiguousDeltas() {
        var transcript = NativePeerTranscript(sessionId: "B:s")
        #expect(!transcript.canDrive)
        transcript.apply(.transcriptSnapshot(sessionId: "B:s", streamingState: "idle", canDrive: true,
                                              messages: [row("b", index: 2, text: "second"), row("a", index: 1, text: "first")],
                                              firstIndex: 1, totalCount: 2, epoch: 2, revision: 0))
        #expect(transcript.messages.map(\.stableId) == ["a", "b"])
        #expect(transcript.canDrive)
        transcript.apply(.transcriptDelta(sessionId: "B:s", streamingState: "streaming", canDrive: true,
                                           upserts: [row("b", index: 2, text: "updated")], epoch: 2, revision: 1))
        #expect(transcript.messages.count == 2)
        #expect(transcript.messages.last?.text == "updated")
        transcript.apply(.transcriptDelta(sessionId: "B:s", streamingState: "idle", canDrive: false,
                                           upserts: [row("c", index: 3, text: "duplicate")], epoch: 2, revision: 1))
        transcript.apply(.transcriptDelta(sessionId: "B:s", streamingState: "idle", canDrive: false,
                                           upserts: [row("c", index: 3, text: "skipped")], epoch: 2, revision: 3))
        #expect(transcript.messages.count == 2)
        #expect(transcript.canDrive)
    }

    @Test func epochAndSessionIsolation() {
        var transcript = NativePeerTranscript(sessionId: "B:s")
        transcript.apply(.transcriptSnapshot(sessionId: "B:s", streamingState: "idle", canDrive: true,
                                              messages: [row("new", index: 10, text: "new")],
                                              firstIndex: 10, totalCount: 11, epoch: 3, revision: 0))
        transcript.apply(.transcriptPage(sessionId: "B:s", epoch: 2, firstIndex: 0,
                                          messages: [row("stale", index: 0, text: "stale")]))
        transcript.apply(.transcriptDelta(sessionId: "B:other", streamingState: "idle", canDrive: false,
                                           upserts: [row("wrong", index: 11, text: "wrong")], epoch: 3, revision: 1))
        #expect(transcript.messages.map(\.stableId) == ["new"])
        #expect(transcript.canDrive)
        transcript.apply(.transcriptPage(sessionId: "B:s", epoch: 3, firstIndex: 9,
                                          messages: [row("older", index: 9, text: "older")]))
        #expect(transcript.messages.map(\.stableId) == ["older", "new"])
        #expect(transcript.olderPageBeforeIndex == 9)
        transcript.apply(.transcriptSnapshot(sessionId: "B:s", streamingState: "idle", canDrive: false,
                                              messages: [row("replacement", index: 0, text: "replacement")],
                                              firstIndex: 0, totalCount: 1, epoch: 4, revision: 0))
        #expect(transcript.messages.map(\.stableId) == ["replacement"])
        #expect(!transcript.canDrive)
    }

    @Test func pendingPermissionAndClosure() {
        var transcript = NativePeerTranscript(sessionId: "B:s")
        transcript.apply(.transcriptSnapshot(sessionId: "B:s", streamingState: "idle", canDrive: true,
                                              messages: [], firstIndex: 0, totalCount: 0, epoch: 1, revision: 0))
        let request = RemotePermissionPayload(requestId: 8, toolName: "Shell", options: [])
        transcript.apply(.permissionRequest(sessionId: "B:s", payload: request))
        #expect(transcript.pendingPermission?.requestId == 8)
        transcript.apply(.permissionResolved(sessionId: "B:s", requestId: 7))
        #expect(transcript.pendingPermission?.requestId == 8)
        transcript.apply(.permissionResolved(sessionId: "B:s", requestId: 8))
        #expect(transcript.pendingPermission == nil)
        transcript.apply(.sessionClosed(sessionId: "B:s"))
        #expect(transcript.isClosed)
        #expect(!transcript.canDrive)
    }
}
