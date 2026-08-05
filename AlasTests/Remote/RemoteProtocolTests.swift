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
            canDrive: false,
            messages: [RemoteWireMessage(stableId: "m0", kind: "agent", text: "hi", json: nil, index: 0)],
            firstIndex: 0,
            totalCount: 1,
            epoch: 0,
            revision: 0
        )
        #expect(try roundTrip(snap) == snap)
    }

    @Test func sessionListRoundTrips() throws {
        let list = RemoteServerMessage.sessionList(sessions: [
            RemoteSessionSummary(id: "s1", title: "Build feature", agentId: "claude", status: "streaming", canDrive: false)
        ])
        #expect(try roundTrip(list) == list)
    }

    @Test func sessionSummaryRoundTripsWithoutWorktreePayload() throws {
        let summary = RemoteSessionSummary(
            id: "s1",
            title: "Build feature",
            agentId: "claude",
            status: "idle",
            canDrive: true,
            isActive: false
        )
        #expect(try roundTrip(summary) == summary)
    }

    @Test func sessionSummaryRoundTripsWithWorktreePayload() throws {
        let summary = RemoteSessionSummary(
            id: "s1",
            title: "Build feature",
            agentId: "claude",
            status: "streaming",
            canDrive: false,
            worktree: RemoteWorktreeSummary(
                projectName: "alas",
                worktreeName: "nacho-improve-remote-sessions",
                branch: "nacho/improve-remote-sessions",
                path: "/tmp/alas",
                metricsAvailable: true,
                comparisonRef: "origin/main",
                commitCount: 3,
                changedFileCount: 7,
                addedLines: 184,
                deletedLines: 39,
                conflictCount: 0
            )
        )
        #expect(try roundTrip(summary) == summary)
    }

    @Test func worktreeOptionRoundTrips() throws {
        let option = RemoteWorktreeOption(
            id: "wt1",
            projectName: "alas",
            worktreeName: "feature-a",
            branch: "nacho/feature-a",
            path: "/tmp/alas-feature-a",
            metricsAvailable: true,
            comparisonRef: "origin/main",
            commitCount: 2,
            changedFileCount: 3,
            addedLines: 10,
            deletedLines: 4,
            conflictCount: 1
        )
        #expect(try roundTrip(option) == option)
    }

    @Test func agentOptionRoundTrips() throws {
        let option = RemoteAgentOption(id: "claude", name: "Claude", isDefault: true)
        #expect(try roundTrip(option) == option)
    }

    @Test func clientCreationMessagesRoundTrip() throws {
        #expect(try roundTrip(RemoteClientMessage.listWorktrees) == .listWorktrees)
        #expect(try roundTrip(RemoteClientMessage.listAgents) == .listAgents)
        #expect(
            try roundTrip(RemoteClientMessage.createSession(worktreeId: "wt1", agentId: "claude"))
                == .createSession(worktreeId: "wt1", agentId: "claude")
        )
    }

    @Test func clientCreationMessagesDecode() throws {
        let worktrees = try JSONDecoder().decode(
            RemoteClientMessage.self,
            from: Data(#"{"type":"listWorktrees"}"#.utf8)
        )
        #expect(worktrees == .listWorktrees)

        let agents = try JSONDecoder().decode(
            RemoteClientMessage.self,
            from: Data(#"{"type":"listAgents"}"#.utf8)
        )
        #expect(agents == .listAgents)

        let create = try JSONDecoder().decode(
            RemoteClientMessage.self,
            from: Data(#"{"type":"createSession","worktreeId":"wt1","agentId":"claude"}"#.utf8)
        )
        #expect(create == .createSession(worktreeId: "wt1", agentId: "claude"))
    }

    @Test func serverCreationMessagesRoundTrip() throws {
        let worktree = RemoteWorktreeOption(
            id: "wt1",
            projectName: "alas",
            worktreeName: "feature-a",
            branch: "nacho/feature-a",
            path: "/tmp/alas-feature-a",
            metricsAvailable: false,
            comparisonRef: nil,
            commitCount: 0,
            changedFileCount: 0,
            addedLines: 0,
            deletedLines: 0,
            conflictCount: 0
        )
        let agent = RemoteAgentOption(id: "claude", name: "Claude", isDefault: true)
        let session = RemoteSessionSummary(
            id: "s1",
            title: "New session",
            agentId: "claude",
            status: "idle",
            canDrive: true
        )

        #expect(try roundTrip(RemoteServerMessage.worktreeList(worktrees: [worktree])) == .worktreeList(worktrees: [worktree]))
        #expect(try roundTrip(RemoteServerMessage.agentList(agents: [agent])) == .agentList(agents: [agent]))
        #expect(try roundTrip(RemoteServerMessage.sessionCreated(session: session)) == .sessionCreated(session: session))
        #expect(try roundTrip(RemoteServerMessage.createSessionFailed(message: "Could not create session.")) == .createSessionFailed(message: "Could not create session."))
    }

    @Test func sessionSummaryDecodesLegacyPayloadWithoutWorktree() throws {
        let json = #"{"id":"s1","title":"T","agentId":"codex","status":"idle","canDrive":false}"#
        let decoded = try JSONDecoder().decode(RemoteSessionSummary.self, from: Data(json.utf8))
        #expect(decoded == RemoteSessionSummary(id: "s1", title: "T", agentId: "codex", status: "idle", canDrive: false))
        #expect(decoded.isActive)
    }

    @Test func sessionSummaryDecodesInactivePayload() throws {
        let json = #"{"id":"s1","title":"T","agentId":"codex","status":"idle","canDrive":false,"isActive":false}"#
        let decoded = try JSONDecoder().decode(RemoteSessionSummary.self, from: Data(json.utf8))
        #expect(decoded == RemoteSessionSummary(id: "s1", title: "T", agentId: "codex", status: "idle", canDrive: false, isActive: false))
    }

    @Test func transcriptDeltaRoundTrips() throws {
        let delta = RemoteServerMessage.transcriptDelta(
            sessionId: "s1",
            streamingState: "idle",
            canDrive: false,
            upserts: [RemoteWireMessage(stableId: "m1", kind: "toolCall", text: nil, json: #"{"name":"bash"}"#, index: 1)],
            epoch: 0,
            revision: 0
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

    @Test func promptRejectedRoundTrips() throws {
        let rejected = RemoteServerMessage.promptRejected(sessionId: "s1")
        #expect(try roundTrip(rejected) == rejected)
    }

    @Test func questionRequestRoundTrips() throws {
        let req = RemoteServerMessage.questionRequest(
            sessionId: "s1",
            payload: RemoteQuestionPayload(
                requestId: 4,
                title: "Pick one",
                questions: [
                    RemoteQuestion(
                        id: "q1",
                        prompt: "Which approach?",
                        options: [
                            RemoteQuestionOption(id: "o1", label: "A"),
                            RemoteQuestionOption(id: "o2", label: "B"),
                        ],
                        allowMultiple: false)
                ]))
        #expect(try roundTrip(req) == req)
    }

    @Test func questionResolvedRoundTrips() throws {
        let resolved = RemoteServerMessage.questionResolved(sessionId: "s1", requestId: 4)
        #expect(try roundTrip(resolved) == resolved)
    }

    @Test func clientMessageDecodesQuestionAnswer() throws {
        let json = #"{"type":"questionAnswer","sessionId":"s1","requestId":4,"answers":[{"questionId":"q1","selectedOptionIds":["o1","o2"]}]}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(RemoteClientMessage.self, from: json)
        #expect(msg == .questionAnswer(
            sessionId: "s1",
            requestId: 4,
            answers: [RemoteQuestionAnswer(questionId: "q1", selectedOptionIds: ["o1", "o2"])]))
    }

    @Test func questionAnswerRoundTrips() throws {
        let msg = RemoteClientMessage.questionAnswer(
            sessionId: "s1",
            requestId: 4,
            answers: [RemoteQuestionAnswer(questionId: "q1", selectedOptionIds: ["o1"])])
        #expect(try roundTrip(msg) == msg)
    }

    @Test func elicitationMessagesRoundTrip() throws {
        let payload = RemoteElicitationPayload(
            requestId: UUID().uuidString,
            title: "Configure",
            message: "Choose a strategy",
            mode: "form",
            fields: [
                .init(
                    key: "strategy",
                    type: "string",
                    title: "Strategy",
                    description: nil,
                    required: true,
                    minLength: nil,
                    maxLength: nil,
                    minimum: nil,
                    maximum: nil,
                    minItems: nil,
                    maxItems: nil,
                    format: nil,
                    pattern: nil,
                    options: [.init(value: "safe", title: "Safe", description: nil)],
                    defaultValue: .string("safe")
                )
            ],
            elicitationId: nil,
            url: nil
        )
        let request = RemoteServerMessage.elicitationRequest(sessionId: "s1", payload: payload)
        #expect(try roundTrip(request) == request)
        #expect(try roundTrip(RemoteServerMessage.elicitationResolved(
            sessionId: "s1",
            requestId: payload.requestId
        )) == .elicitationResolved(sessionId: "s1", requestId: payload.requestId))

        let response = RemoteClientMessage.elicitationResponse(
            sessionId: "s1",
            requestId: payload.requestId,
            action: "accept",
            content: ["strategy": .string("safe")]
        )
        #expect(try roundTrip(response) == response)
    }

    @Test func clientMessageDecodesSendPrompt() throws {
        let json = #"{"type":"sendPrompt","sessionId":"s1","text":"hello"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(RemoteClientMessage.self, from: json)
        #expect(msg == .sendPrompt(sessionId: "s1", text: "hello", attachments: [], intent: "auto"))
    }

    @Test func clientMessageDecodesTakeOverAndStop() throws {
        let t = try JSONDecoder().decode(RemoteClientMessage.self, from: #"{"type":"takeOver","sessionId":"s1"}"#.data(using: .utf8)!)
        #expect(t == .takeOver(sessionId: "s1"))
        let s = try JSONDecoder().decode(RemoteClientMessage.self, from: #"{"type":"stop","sessionId":"s1"}"#.data(using: .utf8)!)
        #expect(s == .stop(sessionId: "s1"))
    }

    @Test func sessionSummaryCarriesCanDrive() throws {
        let list = RemoteServerMessage.sessionList(sessions: [
            RemoteSessionSummary(id: "s1", title: "T", agentId: "claude", status: "idle", canDrive: true)
        ])
        let data = try JSONEncoder().encode(list)
        #expect(try JSONDecoder().decode(RemoteServerMessage.self, from: data) == list)
    }

    @Test func snapshotCarriesCanDrive() throws {
        let snap = RemoteServerMessage.transcriptSnapshot(
            sessionId: "s1", streamingState: "idle", canDrive: true, messages: [],
            firstIndex: 0, totalCount: 0, epoch: 0, revision: 0)
        let data = try JSONEncoder().encode(snap)
        #expect(try JSONDecoder().decode(RemoteServerMessage.self, from: data) == snap)
    }

    @Test func clientDriveVerbsRoundTrip() throws {
        #expect(try roundTrip(RemoteClientMessage.takeOver(sessionId: "s1")) == .takeOver(sessionId: "s1"))
        #expect(try roundTrip(RemoteClientMessage.sendPrompt(sessionId: "s1", text: "hello", attachments: [], intent: "auto")) == .sendPrompt(sessionId: "s1", text: "hello", attachments: [], intent: "auto"))
        #expect(try roundTrip(RemoteClientMessage.stop(sessionId: "s1")) == .stop(sessionId: "s1"))
    }

    @Test func sessionConfigRoundTrips() throws {
        let cfg = RemoteServerMessage.sessionConfig(.init(
            sessionId: "s1",
            models: [.init(id: "opus", name: "Opus"), .init(id: "sonnet", name: "Sonnet")],
            modes: [.init(id: "ask", name: "Ask")],
            currentModel: "opus", currentMode: "ask",
            autoRunEnabled: true, acceptsImages: true))
        #expect(try roundTrip(cfg) == cfg)
    }

    @Test func clientConfigVerbsDecode() throws {
        let setModel = try JSONDecoder().decode(RemoteClientMessage.self,
            from: Data(#"{"type":"setModel","sessionId":"s1","modelId":"opus"}"#.utf8))
        #expect(setModel == .setModel(sessionId: "s1", modelId: "opus"))
        let setMode = try JSONDecoder().decode(RemoteClientMessage.self,
            from: Data(#"{"type":"setMode","sessionId":"s1","modeId":"ask"}"#.utf8))
        #expect(setMode == .setMode(sessionId: "s1", modeId: "ask"))
        let setAuto = try JSONDecoder().decode(RemoteClientMessage.self,
            from: Data(#"{"type":"setAutoRun","sessionId":"s1","enabled":true}"#.utf8))
        #expect(setAuto == .setAutoRun(sessionId: "s1", enabled: true))
    }

    @Test func clientConfigVerbsRoundTrip() throws {
        // Guards against an encoder-side modelId/modeId key mixup.
        #expect(try roundTrip(RemoteClientMessage.setModel(sessionId: "s1", modelId: "opus")) == .setModel(sessionId: "s1", modelId: "opus"))
        #expect(try roundTrip(RemoteClientMessage.setMode(sessionId: "s1", modeId: "ask")) == .setMode(sessionId: "s1", modeId: "ask"))
        #expect(try roundTrip(RemoteClientMessage.setAutoRun(sessionId: "s1", enabled: true)) == .setAutoRun(sessionId: "s1", enabled: true))
    }

    @Test func clientRenameSessionRoundTrips() throws {
        let msg = RemoteClientMessage.renameSession(sessionId: "s1", title: "Build feature")
        #expect(try roundTrip(msg) == msg)
    }

    @Test func clientRenameSessionDecodes() throws {
        let json = #"{"type":"renameSession","sessionId":"s1","title":"Build feature"}"#
        let msg = try JSONDecoder().decode(RemoteClientMessage.self, from: Data(json.utf8))
        #expect(msg == .renameSession(sessionId: "s1", title: "Build feature"))
    }

    @Test func sessionRenamedRoundTrips() throws {
        let msg = RemoteServerMessage.sessionRenamed(sessionId: "s1", title: "Build feature")
        #expect(try roundTrip(msg) == msg)
    }

    @Test func sessionConfigRoundTripsWithNilCurrent() throws {
        // currentModel/currentMode nil → encodeIfPresent omits the keys; decode must still round-trip.
        let cfg = RemoteServerMessage.sessionConfig(.init(
            sessionId: "s1", models: [], modes: [],
            currentModel: nil, currentMode: nil,
            autoRunEnabled: false, acceptsImages: false))
        #expect(try roundTrip(cfg) == cfg)
    }

    @Test func sendPromptWithAttachmentsRoundTrips() throws {
        let msg = RemoteClientMessage.sendPrompt(
            sessionId: "s1",
            text: "look",
            attachments: [RemoteAttachment(name: "a.png", mimeType: "image/png", dataBase64: "AAAA")],
            intent: "auto")
        #expect(try roundTrip(msg) == msg)
    }

    @Test func fetchOlderRoundTrips() throws {
        let msg = RemoteClientMessage.fetchOlder(sessionId: "s1", beforeIndex: 120, limit: 90)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(RemoteClientMessage.self, from: data)
        #expect(decoded == msg)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""type":"fetchOlder""#))
    }

    @Test func windowedSnapshotRoundTrips() throws {
        let wire = [RemoteWireMessage(stableId: "m110", kind: "agent", text: "hi", json: nil, index: 110)]
        let msg = RemoteServerMessage.transcriptSnapshot(
            sessionId: "s1", streamingState: "idle", canDrive: true,
            messages: wire, firstIndex: 110, totalCount: 200, epoch: 3, revision: 0)
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(msg))
        #expect(decoded == msg)
    }

    @Test func deltaCarriesEpochAndRevision() throws {
        let msg = RemoteServerMessage.transcriptDelta(
            sessionId: "s1", streamingState: "streaming", canDrive: false,
            upserts: [], epoch: 3, revision: 7)
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(msg))
        #expect(decoded == msg)
    }

    @Test func transcriptPageRoundTrips() throws {
        let wire = [RemoteWireMessage(stableId: "m20", kind: "user", text: "old", json: nil, index: 20)]
        let msg = RemoteServerMessage.transcriptPage(sessionId: "s1", epoch: 3, firstIndex: 20, messages: wire)
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(msg))
        #expect(decoded == msg)
    }

    @Test func stopPendingRoundTrips() throws {
        let msg = RemoteServerMessage.stopPending(sessionId: "s1")
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(msg))
        #expect(decoded == msg)
    }

    @Test func onlyStopIsControl() {
        #expect(RemoteClientMessage.stop(sessionId: "s").isControl)
        #expect(!RemoteClientMessage.subscribe(sessionId: "s").isControl)
        #expect(!RemoteClientMessage.takeOver(sessionId: "s").isControl)
        #expect(!RemoteClientMessage.fetchOlder(sessionId: "s", beforeIndex: 0, limit: 1).isControl)
    }

    @Test func clientMessageDecodesQueueVerbs() throws {
        let force = #"{"type":"queueForceSend","sessionId":"s1","itemId":"i1"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(RemoteClientMessage.self, from: force)
            == .queueForceSend(sessionId: "s1", itemId: "i1"))

        let remove = #"{"type":"queueRemove","sessionId":"s1","itemId":"i2"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(RemoteClientMessage.self, from: remove)
            == .queueRemove(sessionId: "s1", itemId: "i2"))

        let retry = #"{"type":"queueRetry","sessionId":"s1","itemId":"i3"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(RemoteClientMessage.self, from: retry)
            == .queueRetry(sessionId: "s1", itemId: "i3"))

        let edit = #"{"type":"queueEdit","sessionId":"s1","itemId":"i4"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(RemoteClientMessage.self, from: edit)
            == .queueEdit(sessionId: "s1", itemId: "i4"))

        let clear = #"{"type":"queueClear","sessionId":"s1"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(RemoteClientMessage.self, from: clear)
            == .queueClear(sessionId: "s1"))

        let undo = #"{"type":"queueSteerUndo","sessionId":"s1"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(RemoteClientMessage.self, from: undo)
            == .queueSteerUndo(sessionId: "s1"))
    }

    @Test func queueVerbsRoundTrip() throws {
        let messages: [RemoteClientMessage] = [
            .queueForceSend(sessionId: "s1", itemId: "i1"),
            .queueRemove(sessionId: "s1", itemId: "i2"),
            .queueRetry(sessionId: "s1", itemId: "i3"),
            .queueEdit(sessionId: "s1", itemId: "i4"),
            .queueClear(sessionId: "s1"),
            .queueSteerUndo(sessionId: "s1"),
        ]
        for message in messages {
            #expect(try roundTrip(message) == message)
        }
    }

    @Test func sendPromptWithoutIntentDecodesAsAuto() throws {
        let json = #"{"type":"sendPrompt","sessionId":"s1","text":"hi"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(RemoteClientMessage.self, from: json)
        #expect(msg == .sendPrompt(sessionId: "s1", text: "hi", attachments: [], intent: "auto"))
    }

    @Test func sendPromptCarriesSteerIntent() throws {
        let json = #"{"type":"sendPrompt","sessionId":"s1","text":"hi","intent":"steer"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(RemoteClientMessage.self, from: json)
        #expect(msg == .sendPrompt(sessionId: "s1", text: "hi", attachments: [], intent: "steer"))
        #expect(try roundTrip(msg) == msg)
    }

    @Test func queueStateRoundTrips() throws {
        let state = RemoteServerMessage.queueState(
            sessionId: "s1",
            items: [
                RemoteQueuedPrompt(id: "i1", text: "first", imageCount: 0, status: "sending", lastError: nil),
                RemoteQueuedPrompt(id: "i2", text: "second", imageCount: 2, status: "pending", lastError: "boom"),
            ],
            steerUndoAvailable: true)
        #expect(try roundTrip(state) == state)
    }

    @Test func queueEditRestoredRoundTrips() throws {
        let restored = RemoteServerMessage.queueEditRestored(sessionId: "s1", itemId: "i1", text: "edit me")
        #expect(try roundTrip(restored) == restored)
    }

    @Test func queueVerbsAreDriveOrdering() {
        #expect(RemoteClientMessage.queueForceSend(sessionId: "s1", itemId: "i1").isDriveOrdering)
        #expect(RemoteClientMessage.queueRemove(sessionId: "s1", itemId: "i1").isDriveOrdering)
        #expect(RemoteClientMessage.queueRetry(sessionId: "s1", itemId: "i1").isDriveOrdering)
        #expect(RemoteClientMessage.queueEdit(sessionId: "s1", itemId: "i1").isDriveOrdering)
        #expect(RemoteClientMessage.queueClear(sessionId: "s1").isDriveOrdering)
        #expect(RemoteClientMessage.queueSteerUndo(sessionId: "s1").isDriveOrdering)
        #expect(!RemoteClientMessage.listSessions.isDriveOrdering)
    }

    @Test func onlySendPromptAndTakeOverAreDriveOrdering() {
        #expect(RemoteClientMessage.sendPrompt(sessionId: "s", text: "hi", attachments: [], intent: "auto").isDriveOrdering)
        #expect(RemoteClientMessage.takeOver(sessionId: "s").isDriveOrdering)
        #expect(!RemoteClientMessage.subscribe(sessionId: "s").isDriveOrdering)
        #expect(!RemoteClientMessage.fetchOlder(sessionId: "s", beforeIndex: 0, limit: 1).isDriveOrdering)
        #expect(!RemoteClientMessage.stop(sessionId: "s").isDriveOrdering)
        #expect(!RemoteClientMessage.setModel(sessionId: "s", modelId: "m").isDriveOrdering)
        #expect(!RemoteClientMessage.listSessions.isDriveOrdering)
    }
}
