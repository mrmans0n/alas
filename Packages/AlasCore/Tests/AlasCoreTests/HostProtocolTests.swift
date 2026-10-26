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
    private static let review: HostReview = {
        let target = ReviewSessionTarget.localChanges(worktreeID: worktree.id, repositoryPath: worktreePath, scope: .all)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return HostReview(
            summary: HostReviewSummary(
                record: ReviewSessionRecord(id: target.id, target: target, createdAt: date, updatedAt: date), openCommentCount: 1
            ),
            comments: [ReviewDraftComment(
                id: "c", sessionID: target.draftSessionID, fileID: DiffReviewFileID(namespace: "unstaged", path: "a.txt"),
                path: "a.txt", side: .new, startLine: 1, bodyMarkdown: "Why?", state: .active, createdAt: date, updatedAt: date
            )]
        )
    }()

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
        HostClientMessage(id: 18, request: .deleteWorktree(
            worktree: ref, lineageID: "l", branch: "feature", force: false, deleteBranchIfMerged: true, discardUnsavedEdits: true
        )),
        HostClientMessage(id: 19, request: .archiveWorktree(worktree: ref, lineageID: "l", branch: "feature", discardUnsavedEdits: false)),
        HostClientMessage(id: 20, request: .readWorktree(worktree: ref, read: .fileDiff(path: "a.swift", stage: "unstaged", comparisonMode: nil))),
        HostClientMessage(id: 21, request: .listRunScripts(worktree: ref)),
        HostClientMessage(id: 22, request: .restartRun(scriptKey: "repo:dev.sh", worktree: ref)),
        HostClientMessage(id: 23, request: .listReviews(worktree: ref)),
        HostClientMessage(id: 24, request: .mutateReview(worktree: ref, sessionID: "s", mutation: .add(
            fileID: DiffReviewFileID(namespace: "unstaged", path: "a.txt"), path: "a.txt", originalPath: nil,
            anchor: .line(side: .new, startLine: 1, endLine: 2, selectedText: nil), body: "Why?"
        ))),
        HostClientMessage(id: 25, request: .readWorktree(worktree: ref, read: .rangeDiff(
            base: "abc1234", head: "def5678", threeDot: true, path: "b.txt", originalPath: "a.txt"))),
        HostClientMessage(id: 26, request: .readProviderReview(worktree: ref, sessionID: "s", withDiff: true)),
        HostClientMessage(id: 27, request: .openProviderReview(worktree: ref, number: 7)),
        HostClientMessage(id: 28, request: .mutateReviewThread(
            worktree: ref, sessionID: "s", threadID: "t1", kind: .reply, body: "Done."
        )),
        HostClientMessage(id: 29, request: .publishReview(
            worktree: ref, sessionID: "s",
            publish: HostReviewPublish(decision: .requestChanges, body: "Fix it.", draftIDs: ["c"], headSHA: "abc1234")
        )),
        HostClientMessage(id: 30, request: .listStashes(worktree: ref)),
        HostClientMessage(id: 31, request: .stashDiff(worktree: ref, stash: HostStashRef(ref: "stash@{0}", sha: "abc1234"), path: "a.txt")),
        HostClientMessage(id: 32, request: .mutateWorktree(
            worktree: ref, branch: "feature", change: .applyStash(HostStashRef(ref: "stash@{1}", sha: "def5678"))
        )),
        HostClientMessage(id: 33, request: .mutateWorktree(worktree: ref, branch: "feature", change: .continueOperation(kind: .rebase))),
        HostClientMessage(id: 34, request: .mutateWorktree(worktree: ref, branch: "feature", change: .useOurs(path: "a.txt"))),
        HostClientMessage(id: 35, request: .mutateWorktree(worktree: ref, branch: "feature", change: .cherryPick(sha: "abc1234"))),
        HostClientMessage(id: 36, request: .commitDetails(worktree: ref, sha: "abc1234")),
        HostClientMessage(id: 37, request: .mutateWorktree(worktree: ref, branch: "feature", change: .editCommit(
            sha: "abc1234", edit: .dropHunk(path: "a.txt", index: 1, header: "@@ -3 +3 @@"), comparisonMode: nil
        ))),
        HostClientMessage(id: 38, request: .checkpointRestorePreview(
            worktree: ref, id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!, groupIDs: nil
        )),
        HostClientMessage(id: 39, request: .mutateWorktree(worktree: ref, branch: "feature", change: .restoreCheckpoint(
            id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!,
            groupIDs: [UUID(uuidString: "7F9619FF-8B86-D011-B42D-00CF4FC964FF")!], fingerprint: "f"
        ))),
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
        .response(id: 11, result: .failure(error: .worktreeArchive(refusal: .unsavedEdits))),
        .response(id: 12, result: .failure(error: .worktreeDeletion(refusal: .ownedByWorkspaceCheckout("Owned.")))),
        .response(id: 13, result: .worktreeRead(reply: .fileContents(sessionId: "/srv/feature", path: "a.txt", text: "hi", truncated: false))),
        .response(id: 15, result: .reviews(reviews: [review.summary])),
        .response(id: 16, result: .review(review: review)),
        .response(id: 17, result: .providerReview(review: HostProviderReview(
            remote: ShepherdFixtures.request().remote, request: ShepherdFixtures.request(), capabilities: .githubCLI,
            account: "octocat", diff: "diff --git a/a.txt b/a.txt\n", diffTruncated: true
        ))),
        .response(id: 18, result: .reviewThreadMutated(result: ProviderThreadMutationResult(
            refreshedRequest: ShepherdFixtures.request(), providerURL: URL(string: "https://github.com/acme/app/pull/7"),
            warnings: ["w"]
        ))),
        .response(id: 19, result: .reviewPublished(result: ProviderReviewPublishResult(
            published: [ProviderReviewPublishedComment(localDraftID: "c", providerThreadID: "t", providerCommentID: "1", providerURL: nil)],
            failed: [ProviderReviewFailedComment(localDraftID: "d", message: "outdated")],
            refreshedRequest: ShepherdFixtures.request(), warnings: ["w"]
        ))),
        .response(id: 20, result: .stashes(stashes: [GitStash(ref: "stash@{0}", subject: "On main: wip", relativeTime: "now", sha: "abc1234")])),
        .response(id: 21, result: .diff(diff: HostDiff(
            hunks: [RemoteDiffHunk(header: "@@ -0,0 +1 @@", oldStart: 0, newStart: 1, lines: [
                RemoteDiffLine(kind: "add", text: "hi", oldNumber: nil, newNumber: 1, noTrailingNewline: false),
            ])],
            truncated: true, note: "mode changed"
        ))),
        .response(id: 22, result: .commitDetails(details: CommitDetails(
            info: CommitInfo(
                sha: "abc1234", shortSha: "abc1234", author: "Ann", authorInitials: "A", date: Date(timeIntervalSince1970: 0),
                subject: "add a", rawSubject: "feat: add a", conventionalTag: "feat", filesChanged: 1, insertions: 1, deletions: 0
            ),
            body: "", authorEmail: "ann@example.com", parents: ["def5678"],
            files: [CommitChangedFile(path: "b.txt", originalPath: "a.txt", status: "R", add: 1, del: 0)]
        ))),
        .response(id: 23, result: .commitEdited(result: CommitEditResult(currentSha: "fed9876", shaMap: ["abc1234": "fed9876"]))),
        .response(id: 24, result: .checkpointRestorePreview(preview: CheckpointRestorePreview(
            id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!, checkpointID: UUID(uuidString: "7F9619FF-8B86-D011-B42D-00CF4FC964FF")!,
            checkpointLabel: "Before", currentFingerprint: "f",
            groups: [CheckpointRestoreGroup(
                id: UUID(uuidString: "8F9619FF-8B86-D011-B42D-00CF4FC964FF")!, primaryPath: "b.txt", memberPaths: ["a.txt", "b.txt"],
                renameSource: "a.txt",
                effects: [CheckpointRestoreEffect(
                    relativePath: "a.txt", layer: .worktree, head: .absent,
                    before: .regular(blob: CheckpointBlobReference(sha256: String(repeating: "a", count: 64), byteCount: 2), executable: false),
                    after: .absent, removesUntrackedFile: true
                )]
            )],
            blocker: .activeSession, scopeDescription: "This repository only",
            selectedGroupIDs: [UUID(uuidString: "8F9619FF-8B86-D011-B42D-00CF4FC964FF")!]
        ))),
        .response(id: 14, result: .runScripts(scripts: [HostRunScript(
            scope: .repo, fileName: "dev.sh", name: "Dev", cwd: "web", target: RunExecutionTarget(host: nil, workingDirectory: "/srv/feature/web")
        )])),
        .events(events: [
            .worktreeChanged(WorktreeSnapshot(worktree: worktree, operation: .deleting, isArchived: false)),
            .worktreeRemoved(projectID: "p", worktreeID: worktree.id),
            .sessionChanged(session),
            .sessionRemoved(owner: .worktree(worktree.id), id: "s"),
            .runRemoved(id: "r"),
            .worktreeNotice(HostWorktreeNotice(id: UUID(), worktreeID: worktree.id, title: "t", body: "b", reviewSessionID: "s")),
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

    /// A newer host's review of a kind this Mac can't read is left out, not the whole list.
    @Test func aReviewListDecodesWithoutTheReviewsThisMacCannotRead() throws {
        let message = HostServerMessage.response(id: 1, result: .reviews(reviews: [Self.review.summary, Self.review.summary]))
        var json = try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))
        let kind = try #require(json.range(of: #""kind":"local-changes""#))
        json.replaceSubrange(kind, with: #""kind":"stacked-diff""#)
        #expect(try JSONDecoder().decode(HostServerMessage.self, from: Data(json.utf8))
            == .response(id: 1, result: .reviews(reviews: [Self.review.summary])))
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
        #expect(try json(HostClientMessage(id: 1, request: .deleteWorktree(
            worktree: Self.ref, lineageID: "l", branch: "feature", force: false, deleteBranchIfMerged: false, discardUnsavedEdits: true
        ))) == #"{"id":1,"request":{"deleteWorktree":{"branch":"feature","deleteBranchIfMerged":false,"discardUnsavedEdits":true,"force":false,"lineageID":"l","worktree":{"path":"\/srv\/feature","projectID":"p"}}},"version":1}"#)
        #expect(try json(HostServerMessage.response(id: 3, result: .failure(error: .worktreeDeletion(refusal: .unsavedEdits)))) ==
            #"{"response":{"id":3,"result":{"failure":{"error":{"worktreeDeletion":{"refusal":{"unsavedEdits":{}}}}}}}}"#)
        #expect(try json(HostServerMessage.response(id: 4, result: .runScripts(scripts: [HostRunScript(
            scope: .repo, fileName: "dev.sh", name: "Dev", cwd: nil, target: RunExecutionTarget(host: nil, workingDirectory: "/srv/feature")
        )]))) == #"{"response":{"id":4,"result":{"runScripts":{"scripts":[{"fileName":"dev.sh","name":"Dev","scope":"repo","target":{"workingDirectory":"\/srv\/feature"}}]}}}}"#)
    }

    /// A client before `host.worktrees.lifecycle.v1` sends no acknowledgement.
    @Test func anOlderClientsDeleteDecodesWithoutADiscardAcknowledgement() throws {
        let old = #"{"id":1,"request":{"deleteWorktree":{"branch":"feature","deleteBranchIfMerged":false,"force":true,"lineageID":"l","worktree":{"path":"\/srv\/feature","projectID":"p"}}},"version":1}"#
        #expect(try JSONDecoder().decode(HostClientMessage.self, from: Data(old.utf8)).request == .deleteWorktree(
            worktree: Self.ref, lineageID: "l", branch: "feature", force: true, deleteBranchIfMerged: false, discardUnsavedEdits: nil
        ))
    }

    /// The changes reply carries the host's in-progress operation; an older
    /// host sends none, and one this Mac can't read is dropped, not the list.
    @Test func aChangeListCarriesTheHostsOperation() throws {
        let op = MergeOperation.rebase(plan: RebasePlan(
            ontoBranch: "abc", sourceBranch: "main", commits: [.init(sha: "d1", summary: "s", state: .current)]
        ))
        func changeList(_ operation: MergeOperation?) -> RemoteServerMessage {
            .changeList(
                sessionId: "a", comparisonRef: nil, metricsAvailable: true,
                files: [RemoteChangedFile(path: "a.txt", status: "M", add: 1, del: 0, conflict: nil, renameFrom: nil)],
                staged: [], unstaged: [], commits: [], truncated: false, operation: operation
            )
        }
        let data = try JSONEncoder().encode(changeList(op))
        #expect(try JSONDecoder().decode(RemoteServerMessage.self, from: data) == changeList(op))
        guard case .changeList(_, _, _, _, _, _, _, _, _, _, let scoped) = changeList(op).replacingSessionId("b") else {
            Issue.record("expected a changeList")
            return
        }
        #expect(scoped == op)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wire = try #require(json["operation"] as? [String: Any])
        let plan = try #require((wire["rebase"] as? [String: Any])?["plan"] as? [String: Any])
        #expect((plan["commits"] as? [[String: Any]])?.first?["state"] as? String == "current")
        for unreadable in [nil, ["bisect": [String: Any]()]] as [Any?] {
            json["operation"] = unreadable
            #expect(try JSONDecoder().decode(
                RemoteServerMessage.self, from: JSONSerialization.data(withJSONObject: json)
            ) == changeList(nil))
        }
    }

    /// A host without shepherds sends no `shepherd`; a newer one may send one this Mac can't read.
    @Test(arguments: [nil, ##"{"badge":1,"number":"#7"}"##])
    func aSummaryWithoutAReadableShepherdDecodesWithNone(_ shepherd: String?) throws {
        var summary = Self.session
        summary.shepherd = HostSessionShepherd(badge: "fixing", number: "#7", tooltip: "t")
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        json["shepherd"] = try shepherd.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) }
        let decoded = try JSONDecoder().decode(HostSessionSummary.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == Self.session)
    }

    /// A newer host's review status keeps its branch state when this Mac
    /// can't read its pull request, code host or provider capabilities.
    @Test func aReviewStatusDecodesWithoutThePartsThisMacCannotRead() throws {
        let status = ShepherdFixtures.snapshot(ShepherdFixtures.request())
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        var remote = try #require(json["remote"] as? [String: Any])
        remote["kind"] = "bitbucket"
        json["remote"] = remote
        var request = try #require(json["reviewRequest"] as? [String: Any])
        request["mergeState"] = "queued"
        json["reviewRequest"] = request
        json["providerCapabilities"] = ["canMerge": "yes"]
        let decoded = try JSONDecoder().decode(ReviewLoopSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == ReviewLoopSnapshot(
            local: status.local, remote: nil, reviewRequest: nil, providerAvailable: true, providerAuthenticated: true,
            providerCapabilities: .readOnly, errorMessage: nil
        ))
    }

    @Test(arguments: [[], PeerConsoleCapability.appHost, PeerConsoleCapability.headlessHost])
    func helloAdvertisesExactlyTheConsoleCapabilitiesItServes(_ console: [String]) {
        guard case .hello(_, _, _, _, _, let caps) = RemoteServerMessage.hello(
            RemoteServerIdentity(serverId: "s", name: "n", consoleCapabilities: console)) else {
            Issue.record("expected hello")
            return
        }
        #expect(caps == console + [PeerSessionTabsCapability.v1] + HostProtocolCapability.served)
        // An app host keeps git to the user at it; only a headless host adds it.
        #expect(Set(caps).isDisjoint(with: HostProtocolCapability.headlessOnly))
    }

    /// A provider diff over its cap keeps only whole files.
    @Test func aProviderDiffOverItsCapEndsAtTheLastWholeFile() {
        func section(_ name: String, bytes: Int) -> String {
            let header = "diff --git a/\(name) b/\(name)\n"
            return header + String(repeating: "x", count: bytes - header.utf8.count - 1) + "\n"
        }
        let a = section("a", bytes: 100), b = section("b", bytes: 100)
        #expect(HostProviderReview.capped(a + b, maxBytes: 150) == (a, true))
        #expect(HostProviderReview.capped(a + b, maxBytes: 400) == (a + b, false))
        #expect(HostProviderReview.capped(section("c", bytes: 300), maxBytes: 150) == ("", true))
    }

    /// `peers remove` takes an id or server id as is, and a name only when
    /// one peer has it.
    @Test(arguments: [
        ("p1", "p1"), ("srv-2", "p2"), ("Desk", "p3"), ("p2", "p2"),
        ("Laptop", nil), ("nobody", nil),
    ] as [(String, String?)])
    func aPeerIsResolvedByIdServerIdOrUniqueName(query: String, expected: String?) {
        // p4 is named after p2's id: the exact id wins over the name.
        let peers = [
            HostPeerSummary(id: "p1", serverId: "srv-1", name: "Laptop", origins: []),
            HostPeerSummary(id: "p2", serverId: "srv-2", name: "Laptop", origins: []),
            HostPeerSummary(id: "p3", serverId: "srv-3", name: "Desk", origins: []),
            HostPeerSummary(id: "p4", serverId: "srv-4", name: "p2", origins: []),
        ]
        #expect((try? HostPeerSummary.resolve(query, in: peers))?.id == expected)
    }
}
