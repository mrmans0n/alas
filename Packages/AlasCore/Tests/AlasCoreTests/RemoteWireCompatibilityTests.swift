import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

/// The phone decodes the Mac's wire messages with the host channel left
/// opaque, and what it re-encodes is what the Mac sent.
@Suite struct RemoteWireCompatibilityTests {
    typealias PhoneServerMessage = RemoteServerMessageOf<OpaqueHostMessage, OpaqueHostMessage>
    typealias PhoneClientMessage = RemoteClientMessageOf<OpaqueHostMessage, OpaqueHostMessage>

    /// The phone builds git actions without HostProtocol; they must read on the Mac as these requests.
    @Test(arguments: [
        (RemoteGitChange.stage(paths: ["a", "b"]), HostWorktreeChange.stage(paths: ["a", "b"])),
        (.unstage(paths: ["a"]), .unstage(paths: ["a"])),
        (.discard(paths: ["a"]), .discard(paths: ["a"])),
        (.commit(subject: "Fix", body: "Why"), .commit(subject: "Fix", body: "Why", amend: false)),
        (.push, .push(forceWithLease: false)),
        (.pull, .pull),
        (.fetch, .fetch),
    ] as [(RemoteGitChange, HostWorktreeChange)])
    func phoneGitRequestsDecodeOnTheMac(change: RemoteGitChange, expected: HostWorktreeChange) throws {
        let json = RemoteGitRequest.message(id: 7, projectID: "p", path: "/r", branch: "main", change: change).json
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: json) == HostClientMessage(
            id: 7, request: .mutateWorktree(worktree: WorktreeRef(projectID: "p", path: "/r"), branch: "main", change: expected)))
    }

    @Test(arguments: [
        (HostResponse.done, nil),
        (.failure(error: .failed(message: "Nothing is staged to commit.")), "Nothing is staged to commit."),
        (.failure(error: .operationInProgress), "Another operation is running in this worktree. Try again when it finishes."),
        (.failure(error: .session(refusal: .notWriter)), "Another device is driving this session."),
    ] as [(HostResponse, String?)])
    func phoneReadsTheMacsGitReply(result: HostResponse, failure: String?) throws {
        let reply = OpaqueHostMessage(json: try JSONEncoder().encode(HostServerMessage.response(id: 7, result: result)))
        #expect(RemoteGitRequest.reply(to: 8, in: reply) == nil)
        switch try #require(RemoteGitRequest.reply(to: 7, in: reply)) {
        case .success: #expect(failure == nil)
        case .failure(let error): #expect(error.message == failure)
        }
    }

    @Test func phoneShepherdRequestsDecodeOnTheMac() throws {
        let list = try JSONDecoder().decode(HostClientMessage.self, from: RemoteShepherdRequest.list(id: 3).json)
        #expect(list == HostClientMessage(id: 3, request: .listSessions))
        let act = RemoteShepherdRequest.act(id: 4, sessionID: "s", action: .enableAutoMerge).json
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: act)
            == HostClientMessage(id: 4, request: .shepherdSession(sessionID: "s", action: .enableAutoMerge)))
    }

    @Test func phoneReadsASessionsShepherdFromTheMacsList() throws {
        func summary(_ id: String, _ shepherd: HostSessionShepherd?) -> HostSessionSummary {
            var summary = HostSessionSummary(owner: .worktree("w"), id: id, agentId: "codex", title: "t", remoteSessionId: nil,
                                             createdAt: 1, updatedAt: 2, lastOpenedAt: 3, streamingState: nil, isWriter: true)
            summary.shepherd = shepherd
            return summary
        }
        let shepherd = HostSessionShepherd(badge: "fixing", number: "#12", tooltip: "#12 · fixing", resumable: false,
                                           phaseLine: "fixing", autoFix: true, autoMerge: false)
        let reply = OpaqueHostMessage(json: try JSONEncoder().encode(HostServerMessage.response(
            id: 5, result: .sessions(sessions: [summary("a", nil), summary("b", shepherd)]))))
        #expect(RemoteShepherdRequest.shepherd(of: "b", replying: 5, in: reply) == .some(RemoteShepherd(
            badge: "fixing", number: "#12", tooltip: "#12 · fixing", resumable: false, phaseLine: "fixing", autoFix: true, autoMerge: false)))
        #expect(RemoteShepherdRequest.shepherd(of: "a", replying: 5, in: reply) == .some(nil))
        #expect(RemoteShepherdRequest.shepherd(of: "c", replying: 5, in: reply) == nil)
        #expect(RemoteShepherdRequest.shepherd(of: "b", replying: 6, in: reply) == nil)
    }

    @Test(arguments: RemoteWireSamples.serverMessages)
    func macEncodedServerMessageDecodesOnThePhone(_ message: RemoteServerMessage) throws {
        let data = try JSONEncoder.sorted.encode(message)
        let phone = try JSONDecoder().decode(PhoneServerMessage.self, from: data)
        #expect(try JSONEncoder.sorted.encode(phone) == data)
    }

    @MainActor // `toWire` reads a `StreamingText`.
    @Test(arguments: ["commentary", "finalAnswer", "read", "subagent"])
    func toWireCarriesFoldFacts(row: String) {
        let message: ACPMessage = switch row {
        case "commentary": .agent(id: UUID(), messageId: nil, StreamingText("thinking aloud", phase: .commentary))
        case "finalAnswer": .agent(id: UUID(), messageId: nil, StreamingText("done", phase: .finalAnswer))
        case "read": .toolCall(.init(toolCallId: "t", title: "Read a", kind: "read", status: "completed"))
        default: .toolCall(.init(
            toolCallId: "s", title: "Task", kind: "other", status: "completed",
            metadata: AnyCodable(["subagent": AnyCodable(["version": AnyCodable(1), "id": AnyCodable("child")])])))
        }
        let wire = RemoteSessionGateway.toWire(message, index: 0, createdAt: 1_800_000_000_000)
        #expect(wire.createdAt == 1_800_000_000_000)
        #expect(wire.phase == (row == "commentary" ? "commentary" : nil))
        switch row {
        case "read": #expect(wire.fold == .init(joins: true, verb: "read"))
        case "subagent": #expect(wire.fold?.joins == false)
        default: #expect(wire.fold == nil)
        }
        #expect(RemoteSessionGateway.toWire(message, index: 0, createdAt: nil).createdAt == nil)
    }

    @Test(arguments: RemoteWireSamples.clientMessages)
    func phoneEncodedClientMessageDecodesOnTheMac(_ message: RemoteClientMessage) throws {
        let data = try JSONEncoder.sorted.encode(message)
        let phone = try JSONDecoder().decode(PhoneClientMessage.self, from: data)
        let back = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder.sorted.encode(phone))
        #expect(back == message)
    }
}

@Suite struct PushRelayRegistrationTests {
    @Test func registrationWireShapeOmitsANilToken() throws {
        func json(_ token: String?) throws -> [String: String] {
            let data = try JSONEncoder().encode(RemoteClientMessage.pushRegistration(relayURL: "https://r.example", relayToken: token))
            return try JSONDecoder().decode([String: String].self, from: data)
        }
        #expect(try json("t") == ["type": "pushRegistration", "relayURL": "https://r.example", "relayToken": "t"])
        #expect(try json(nil) == ["type": "pushRegistration", "relayURL": "https://r.example"])
    }

    @Test(arguments: [
        ("https://r.example/push", "t", true),
        ("http://r.example/push", "t", false),
        ("not a url", "t", false),
        ("https://r.example/push", "", false),
        ("https://r.example/" + String(repeating: "a", count: 512), "t", false),
        ("https://r.example/push", String(repeating: "a", count: 1025), false),
    ])
    func relayValidationEnforcesSchemeAndCaps(url: String, token: String, valid: Bool) {
        #expect((RemotePushRelay.validated(url: url, token: token) != nil) == valid)
    }

    @Test(arguments: [
        // A phone that names no kinds gets what it got before kinds existed.
        (nil, ["permission", "input"]),
        ([], []),
        // Unknown kinds are dropped.
        (["finished", "everything"], ["finished"]),
    ] as [([String]?, Set<String>)])
    func relayWantsTheKindsThePhoneNamed(kinds: [String]?, wanted: Set<String>) throws {
        let relay = try #require(RemotePushRelay.validated(url: "https://r.example/push", token: "t", kinds: kinds))
        #expect(Set(["permission", "input", "finished"].filter(relay.wants)) == wanted)
    }

    @Test func deviceWithoutPushRelayDecodesNil() throws {
        let json = #"{"id":"d","name":"n","tokenHash":"h","createdAt":0}"#
        #expect(try JSONDecoder().decode(RemoteDevice.self, from: Data(json.utf8)).pushRelay == nil)
    }

    @MainActor @Test func pushRelaySurvivesReloadAndNilClearsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("devices.json")
        FileDeviceStore(url: url).save([RemoteDevice(id: "d1", name: "Phone", tokenHash: "h", createdAt: .distantPast, lastSeenAt: nil)])
        let relay = try #require(RemotePushRelay.validated(url: "https://r.example/push", token: "t"))

        RemotePairingService(store: FileDeviceStore(url: url)).setPushRelay(relay, for: "d1")
        let reloaded = RemotePairingService(store: FileDeviceStore(url: url))
        #expect(reloaded.pushRelays.map(\.deviceID) == ["d1"])
        #expect(reloaded.pushRelays.first?.relay == relay)

        reloaded.setPushRelay(nil, for: "d1")
        #expect(RemotePairingService(store: FileDeviceStore(url: url)).pushRelays.isEmpty)
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
        .transcriptDelta(
            sessionId: "s1", streamingState: "idle", canDrive: true,
            upserts: [
                RemoteWireMessage(
                    stableId: "m6", kind: "agent", text: "Looking around", json: nil, index: 6,
                    phase: "commentary", createdAt: 1_800_000_000_123),
                RemoteWireMessage(
                    stableId: "m7", kind: "toolCall", text: nil, json: #"{"title":"Read a"}"#, index: 7,
                    createdAt: 1_800_000_000_456, fold: .init(joins: true, verb: "read")),
            ],
            epoch: 1, revision: 10, hasCancellableBackgroundWork: false),
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
        .pushRegistration(relayURL: "https://relay.example/push", relayToken: "tok"),
        .pushRegistration(relayURL: "https://relay.example/push", relayToken: nil),
        .pushRegistration(relayURL: "https://relay.example/push", relayToken: "tok", kinds: ["finished", "permission"]),
        .questionAnswer(sessionId: "s1", requestId: 8, answers: [
            RemoteQuestionAnswer(questionId: "q", selectedOptionIds: ["a", "b"]),
        ]),
        .queueMove(sessionId: "s1", itemId: "q1", targetItemId: "q2"),
        .setConfigOption(sessionId: "s1", configId: "thinking", value: .string("high")),
        .host(HostClientMessage(id: 5, request: .listSessions)),
    ]
}
