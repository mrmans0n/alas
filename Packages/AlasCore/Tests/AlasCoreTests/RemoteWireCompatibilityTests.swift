import Foundation
import Testing
@testable import AlasCore

/// The phone decodes the Mac's wire messages with the host channel left
/// opaque, and what it re-encodes is what the Mac sent.
@Suite struct RemoteWireCompatibilityTests {
    typealias PhoneServerMessage = RemoteServerMessageOf<OpaqueHostMessage, OpaqueHostMessage>
    typealias PhoneClientMessage = RemoteClientMessageOf<OpaqueHostMessage, OpaqueHostMessage>

    @Test(arguments: RemoteWireSamples.serverMessages)
    func macEncodedServerMessageDecodesOnThePhone(_ message: RemoteServerMessage) throws {
        let data = try JSONEncoder.sorted.encode(message)
        let phone = try JSONDecoder().decode(PhoneServerMessage.self, from: data)
        #expect(try JSONEncoder.sorted.encode(phone) == data)
    }

    @Test(arguments: RemoteWireSamples.clientMessages)
    func phoneEncodedClientMessageDecodesOnTheMac(_ message: RemoteClientMessage) throws {
        let data = try JSONEncoder.sorted.encode(message)
        let phone = try JSONDecoder().decode(PhoneClientMessage.self, from: data)
        let back = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder.sorted.encode(phone))
        #expect(back == message)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

enum RemoteWireSamples {
    static let serverMessages: [RemoteServerMessage] = [
        .sessionList(sessions: [
            RemoteSessionSummary(
                id: "s1", title: "Fix the build", agentId: "claude", status: "streaming", canDrive: true,
                tabIndex: 2, projectId: "p1", worktreeId: "w1", updatedAt: 1_800_000_000_000),
        ]),
        .transcriptDelta(
            sessionId: "s1", streamingState: "streaming", canDrive: true,
            upserts: [
                RemoteWireMessage(stableId: "m1", kind: "agent", text: "Running the tests/now", json: nil, index: 4),
                RemoteWireMessage(
                    stableId: "m2", kind: "toolCall", text: nil,
                    json: #"{"title":"swift test","status":"completed"}"#, index: 5, isHidden: false),
            ],
            epoch: 1, revision: 9, hasCancellableBackgroundWork: true),
        .permissionRequest(sessionId: "s1", payload: RemotePermissionPayload(
            requestId: 7, toolName: "Bash",
            options: [RemotePermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")],
            title: "Run swift test?", defaultToNo: true, commandSummary: "swift test")),
        .queueState(sessionId: "s1", items: [
            RemoteQueuedPrompt(
                id: "q1", text: "Then commit", imageCount: 1, resourceCount: 0, status: "pending",
                lastError: nil, scheduledAt: 1_800_000_000_123.5, canRemove: true),
        ]),
        .host(.response(id: 3, result: .remotePairingCode(
            code: "123456", expiresAt: Date(timeIntervalSince1970: 1_800_000_000.25), link: nil))),
        .peerHost(HostClientMessage(id: 4, request: .listSessions)),
    ]

    static let clientMessages: [RemoteClientMessage] = [
        .sendPrompt(
            sessionId: "s1", text: "Look at this",
            attachments: [RemoteAttachment(name: "shot.png", mimeType: "image/png", dataBase64: "iVBORw0KGgo=")],
            intent: "queue", mentions: [RemoteMention(kind: RemoteMention.file, value: "a/b.swift", name: "b.swift")]),
        .permissionDecision(sessionId: "s1", requestId: 7, optionId: "allow", persistScope: "session"),
        .questionAnswer(sessionId: "s1", requestId: 8, answers: [
            RemoteQuestionAnswer(questionId: "q", selectedOptionIds: ["a", "b"]),
        ]),
        .queueMove(sessionId: "s1", itemId: "q1", targetItemId: "q2"),
        .setConfigOption(sessionId: "s1", configId: "thinking", value: .string("high")),
        .host(HostClientMessage(id: 5, request: .listSessions)),
    ]
}
