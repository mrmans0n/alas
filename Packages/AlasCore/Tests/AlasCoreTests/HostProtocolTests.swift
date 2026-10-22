import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

struct HostProtocolTests {
    private static let worktreePath = URL(fileURLWithPath: "/srv/feature")
    private static let worktree = Worktree(
        id: Worktree.makeId(path: worktreePath), projectId: "p", name: "feature", branch: "feature",
        path: worktreePath, status: .clean, lastActivity: Date(timeIntervalSince1970: 1_700_000_000)
    )
    private static let session = HostSessionSummary(
        owner: .workspaceCheckout(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!, .ssh("build")),
        id: "s", agentId: "codex", title: "Fix the build", remoteSessionId: "r",
        createdAt: 1, updatedAt: 2, lastOpenedAt: 3, streamingState: .awaitingPermission, isWriter: true
    )
    private static let ref = WorktreeRef(projectID: "p", path: "/srv/feature")

    /// Every kind of message survives the wire unchanged.
    @Test(arguments: [
        HostClientMessage(id: 1, request: .snapshot),
        HostClientMessage(id: 2, request: .subscribe(after: HostCursor(generation: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!, sequence: 42))),
        HostClientMessage(id: 3, request: .addProject(path: "/srv/repo", displayName: "repo", host: "build", kind: .folder)),
        HostClientMessage(id: 4, request: .createWorktree(projectID: "p", base: "main", branch: "b", destination: "/srv/b")),
        HostClientMessage(id: 5, request: .deleteWorktree(worktree: ref, lineageID: "l", branch: "feature", force: true, deleteBranchIfMerged: false)),
        HostClientMessage(id: 6, request: .workspaceCheckout(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!)),
        HostClientMessage(id: 7, request: .stopRun(scriptKey: "dev", worktree: ref)),
        HostClientMessage(id: 8, request: .createSession(target: .workspaceCheckout(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!), agentID: "codex", modelID: "fast", autoRun: true)),
        HostClientMessage(id: 9, request: .setSessionConfigOption(sessionID: "s", configID: "effort", value: .string("high"))),
        HostClientMessage(id: 10, request: .answerPermission(sessionID: "s", requestID: .string("p-1"), optionID: "allow", scope: .project)),
        HostClientMessage(id: 11, request: .answerQuestion(sessionID: "s", requestID: .number(3), answers: [ACPQuestionAnswer(questionId: "q", selectedOptionIds: ["a"])])),
        HostClientMessage(id: 12, request: .respondToUserInput(sessionID: "s", requestID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!, answer: .cancel)),
        HostClientMessage(id: 13, request: .followSession(sessionID: "s", from: TranscriptRevision(epoch: 2, version: 40))),
        HostClientMessage(id: 14, request: .followWorktree(worktreeID: "w")),
        HostClientMessage(id: 15, request: .subscribeAccepting(
            after: HostCursor(generation: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!, sequence: 42), events: ["sessionState"]
        )),
        HostClientMessage(id: 16, request: .runOutput(runID: "r", projectID: "p")),
        HostClientMessage(id: 17, request: .remotePairingCode),
    ])
    func clientMessagesRoundTrip(_ message: HostClientMessage) throws {
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: JSONEncoder().encode(message)) == message)
    }

    @Test(arguments: [
        HostServerMessage.response(id: 1, result: .snapshot(snapshot: HostSnapshot(
            cursor: HostCursor(generation: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!, sequence: 9),
            projects: [ProjectSnapshot(ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: Date(timeIntervalSince1970: 0)))],
            worktrees: [WorktreeSnapshot(worktree: worktree, operation: .createFailed(message: "no space"), isArchived: true)],
            workspaceCheckouts: [],
            runs: [],
            sessions: [session]
        ))),
        .response(id: 2, result: .runStart(start: .refused(title: "No", message: "Busy"))),
        .response(id: 3, result: .failure(error: .worktreeDeletion(refusal: .needsForce("dirty")))),
        .response(id: 4, result: .failure(error: .workspace(error: .checkoutNotFound))),
        .response(id: 5, result: .session(session: session)),
        .response(id: 6, result: .failure(error: .session(refusal: .ownerUnavailable(reason: "busy")))),
        .response(id: 7, result: .capabilities(capabilities: ["host.v1", "host.events.v1"])),
        .response(id: 8, result: .runOutput(output: .text("hello\n", truncated: true))),
        .response(id: 9, result: .runOutput(output: .notFinished)),
        .response(id: 10, result: .remotePairingCode(code: "ABC123", expiresAt: Date(timeIntervalSince1970: 1_800_000_000), link: nil)),
        .events(events: [
            .worktreeChanged(WorktreeSnapshot(worktree: worktree, operation: .deleting, isArchived: false)),
            .worktreeRemoved(projectID: "p", worktreeID: worktree.id),
            .sessionChanged(session),
            .sessionRemoved(owner: .worktree(worktree.id), id: "s"),
            .runRemoved(id: "r"),
            .transcript(owner: .worktree("w"), id: "s", delta: HostTranscriptDelta(
                revision: TranscriptRevision(epoch: 1, version: 5), reset: true,
                messages: [HostTranscriptMessage(index: 0, stableID: "m", kind: "user", payload: #"{"text":"hi"}"#)],
                messageCount: 1, streamingState: .streaming
            )),
            .pendingRequest(owner: .worktree("w"), id: "s", request: .plan(requestID: .number(4), params: ACPCursorCreatePlanParams(
                toolCallId: "t", name: "Plan", overview: "", plan: "Do it", todos: [], isProject: false, phases: []
            ))),
            .pendingRequestResolved(owner: .worktree("w"), id: "s", requestID: .userInput(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!)),
            .sessionState(owner: .worktree("w"), id: "s", state: HostSessionState(
                isWriter: true, hasCancellableBackgroundWork: false,
                config: RemoteSessionConfig(sessionId: "s", models: [], modes: [], currentModel: nil, currentMode: nil, autoRunEnabled: true, acceptsImages: false),
                queue: []
            )),
            .resync,
        ], cursor: HostCursor(generation: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!, sequence: 7)),
    ])
    func serverMessagesRoundTrip(_ message: HostServerMessage) throws {
        #expect(try JSONDecoder().decode(HostServerMessage.self, from: JSONEncoder().encode(message)) == message)
    }

    /// The encoding is the protocol: a change here breaks every client.
    @Test func encodingIsPinned() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func json(_ value: some Encodable) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        #expect(try json(HostClientMessage(id: 1, request: .archiveWorktree(worktree: Self.ref, lineageID: "l", branch: "feature"))) ==
            #"{"id":1,"request":{"archiveWorktree":{"branch":"feature","lineageID":"l","worktree":{"path":"\/srv\/feature","projectID":"p"}}},"version":1}"#)
        #expect(try json(HostServerMessage.events(events: [
            .sessionRemoved(owner: .worktree("w"), id: "s"),
            .runRemoved(id: "r"),
            .resync,
        ], cursor: HostCursor(generation: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!, sequence: 3))) ==
            #"{"events":{"cursor":{"generation":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","sequence":3},"events":[{"sessionRemoved":{"id":"s","owner":{"worktree":{"id":"w"}}}},{"runRemoved":{"id":"r"}},{"resync":{}}]}}"#)
        #expect(try json(HostServerMessage.response(id: 2, result: .failure(error: .worktreeDeletion(refusal: .needsForce("dirty"))))) ==
            #"{"response":{"id":2,"result":{"failure":{"error":{"worktreeDeletion":{"refusal":{"needsForce":{"message":"dirty"}}}}}}}}"#)
    }

    @Test func helloOmitsConsoleCapabilitiesForAServerWithoutConsoles() {
        guard case .hello(_, _, _, _, _, let caps) = RemoteServerMessage.hello(
            RemoteServerIdentity(serverId: "s", name: "n", servesPeerConsoles: false)) else {
            Issue.record("expected hello")
            return
        }
        #expect(!caps.contains(PeerConsoleCapability.v1))
        #expect(!caps.contains(PeerConsoleCapability.terminateV1))
        #expect(caps.contains(PeerSessionTabsCapability.v1))
    }
}
