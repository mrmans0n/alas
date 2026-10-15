import Foundation
import Testing
@testable import AlasCore

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
        .events(events: [
            .worktreeChanged(WorktreeSnapshot(worktree: worktree, operation: .deleting, isArchived: false)),
            .worktreeRemoved(projectID: "p", worktreeID: worktree.id),
            .sessionChanged(session),
            .sessionRemoved(owner: .worktree(worktree.id), id: "s"),
            .runRemoved(id: "r"),
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
}
